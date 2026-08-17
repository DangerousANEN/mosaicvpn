package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

// Account cabinet endpoints (T-19).
//
// Linking is code-based rather than telegram_id-based. A Telegram ID is a
// public identifier: anyone who knows a victim's ID could POST it to a local
// daemon and bind a client to that account, exposing tariff, traffic and
// payment history. A short-lived single-use code shown only inside the user's
// own bot chat proves the person driving the client also controls the
// Telegram account.

// linkCodeIssueRequest is the bot-facing payload asking for a pairing code.
type linkCodeIssueRequest struct {
	TelegramID   int64  `json:"telegram_id"`
	Username     string `json:"username,omitempty"`
	SessionToken string `json:"session_token,omitempty"`
	// TTLSeconds optionally overrides the default validity window.
	TTLSeconds int `json:"ttl_seconds,omitempty"`
}

// linkCodeIssueResponse carries the freshly issued code back to the bot.
type linkCodeIssueResponse struct {
	Code      string `json:"code"`
	ExpiresAt string `json:"expires_at"`
	TTLSecond int    `json:"ttl_seconds"`
}

// handleLinkCodeIssue mints a pairing code for a Telegram account.
//
// POST /v1/account/link-code   { "telegram_id": 123, "username": "alice" }
func (s *Server) handleLinkCodeIssue(w http.ResponseWriter, r *http.Request) {
	var req linkCodeIssueRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body: "+err.Error())
		return
	}
	if req.TelegramID == 0 {
		writeError(w, http.StatusBadRequest, "telegram_id required")
		return
	}

	ttl := store.DefaultLinkCodeTTL
	if req.TTLSeconds > 0 {
		ttl = time.Duration(req.TTLSeconds) * time.Second
	}

	code, err := s.store.IssueLinkCode(req.TelegramID, req.Username, req.SessionToken, ttl)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "store: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, linkCodeIssueResponse{
		Code:      code.Code,
		ExpiresAt: formatTime(code.ExpiresAt),
		TTLSecond: int(ttl.Seconds()),
	})
}

// linkCodeRedeemRequest is the client-facing payload carrying a typed code.
type linkCodeRedeemRequest struct {
	Code string `json:"code"`
}

type emailLoginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

const mosaicProviderSubscriptionID = "provider-mosaicvpn-primary"

// mosaicProviderSubscription represents the service-owned route catalog. It
// is deliberately a normal provider source named MosaicVPN; `mosaic-direct`
// remains only as a migration alias for legacy local state.
func mosaicProviderSubscription(feedURL string) proto.Subscription {
	return proto.Subscription{
		ID:                     mosaicProviderSubscriptionID,
		Name:                   "MosaicVPN",
		URL:                    feedURL,
		AutoRefresh:            true,
		RefreshIntervalSeconds: 3600,
		Source:                 proto.SubscriptionSourceProvider,
		ProviderID:             "mosaicvpn",
		ProviderAccountID:      "mosaicvpn-default",
		HidePhysicalNodes:      true,
	}
}

// handleEmailLogin authorizes a password account at the provider and creates
// a personal direct feed subscription. The password never reaches disk.
func (s *Server) handleEmailLogin(w http.ResponseWriter, r *http.Request) {
	var req emailLoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if req.Email == "" || req.Password == "" {
		writeError(w, http.StatusBadRequest, "email and password required")
		return
	}
	auth := s.emailAuthenticator
	if auth == nil {
		writeError(w, http.StatusServiceUnavailable, "email login is unavailable")
		return
	}
	res, err := auth.Login(r.Context(), req.Email, req.Password)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid email or password")
		return
	}
	if err := s.store.SetAccount(store.Account{SessionToken: res.SessionToken, DirectToken: res.ClientToken, DirectFeedURL: res.DirectFeedURL, Username: res.Email, Email: res.Email}); err != nil {
		writeError(w, http.StatusInternalServerError, "store: "+err.Error())
		return
	}
	directSub := mosaicProviderSubscription(res.DirectFeedURL)
	if _, err := s.store.AddOrUpdateSubscription(directSub); err != nil {
		writeError(w, http.StatusInternalServerError, "store direct subscription: "+err.Error())
		return
	}
	if err := s.refresh(r.Context(), directSub); err != nil {
		writeError(w, http.StatusBadGateway, "direct subscription fetch: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "direct_ready": true, "email": res.Email})
}

// handleLinkCodeRedeem exchanges a pairing code for a linked account.
//
// POST /v1/account/link   { "code": "AB23CD45" }
func (s *Server) handleLinkCodeRedeem(w http.ResponseWriter, r *http.Request) {
	var req linkCodeRedeemRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body: "+err.Error())
		return
	}
	if req.Code == "" {
		writeError(w, http.StatusBadRequest, "code required")
		return
	}

	// Remote-first: the bot is the authority in the hosted topology, because
	// it is the side that showed the code to the user. The local store is
	// only meaningful for self-hosted setups where no bot is configured.
	if v := s.linkVerifier; v != nil {
		res, verr := v.Verify(r.Context(), req.Code)
		switch {
		case verr == nil:
			if serr := s.store.SetAccount(store.Account{
				TelegramID:    res.TelegramID,
				SessionToken:  res.SessionToken,
				DirectToken:   res.DirectToken,
				DirectFeedURL: res.DirectFeedURL,
				Username:      res.Username,
			}); serr != nil {
				writeError(w, http.StatusInternalServerError, "store: "+serr.Error())
				return
			}
			// The direct subscription is only created after a successful pairing.
			// Existing manually added subscriptions are left untouched.
			if res.DirectFeedURL != "" {
				directSub := mosaicProviderSubscription(res.DirectFeedURL)
				if _, serr := s.store.AddOrUpdateSubscription(directSub); serr != nil {
					writeError(w, http.StatusInternalServerError, "store direct subscription: "+serr.Error())
					return
				}
				if serr := s.refresh(r.Context(), directSub); serr != nil {
					writeError(w, http.StatusBadGateway, "direct subscription fetch: "+serr.Error())
					return
				}
			}
			writeJSON(w, http.StatusOK, map[string]any{
				"ok":           true,
				"telegram_id":  res.TelegramID,
				"direct_ready": res.DirectFeedURL != "",
				"username":     res.Username,
			})
			return
		case errors.Is(verr, ErrLinkCodeMalformed):
			writeError(w, http.StatusBadRequest, "pairing code must contain 8 valid symbols")
			return
		case errors.Is(verr, errLinkNotFound):

			writeError(w, http.StatusNotFound, "code not found")
			return
		case errors.Is(verr, errLinkExpired):
			writeError(w, http.StatusGone, "code expired")
			return
		case errors.Is(verr, errLinkUsed):
			writeError(w, http.StatusConflict, "code already used")
			return
		case errors.Is(verr, errLinkAttempts):
			writeError(w, http.StatusTooManyRequests, "too many attempts")
			return
		case errors.Is(verr, ErrVerifierUnavailable):
			// Do not silently fall through to the local store: that would
			// tell the user "code not found" when the real problem is that
			// the bot is unreachable, sending them to re-request codes that
			// can never work.
			writeError(w, http.StatusServiceUnavailable,
				"cannot reach the account service, try again shortly")
			return
		default:
			writeError(w, http.StatusBadGateway, "verify: "+verr.Error())
			return
		}
	}

	code, err := s.store.RedeemLinkCode(req.Code)
	if err != nil {
		// Distinguish the failure modes so the UI can say something true
		// ("code expired, ask the bot for a new one") instead of a generic
		// error. All of them are 4xx: none is the daemon's fault.
		switch {
		case errors.Is(err, store.ErrLinkCodeNotFound):
			writeError(w, http.StatusNotFound, "code not found")
		case errors.Is(err, store.ErrLinkCodeExpired):
			writeError(w, http.StatusGone, "code expired")
		case errors.Is(err, store.ErrLinkCodeUsed):
			writeError(w, http.StatusConflict, "code already used")
		case errors.Is(err, store.ErrLinkCodeAttempts):
			writeError(w, http.StatusTooManyRequests, "too many attempts")
		default:
			writeError(w, http.StatusInternalServerError, "store: "+err.Error())
		}
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"telegram_id": code.TelegramID,
		"username":    code.Username,
	})
}

// paymentEntryResponse is one row of payment history for the cabinet.
type paymentEntryResponse struct {
	ID          string  `json:"id"`
	Provider    string  `json:"provider"`
	Amount      float64 `json:"amount"`
	Currency    string  `json:"currency"`
	Status      string  `json:"status"`
	Days        int     `json:"days,omitempty"`
	Description string  `json:"description,omitempty"`
	CreatedAt   string  `json:"created_at"`
	PaidAt      string  `json:"paid_at,omitempty"`
}

// handlePaymentHistory returns the account's payment history, newest first.
//
// GET /v1/account/payments
func (s *Server) handlePaymentHistory(w http.ResponseWriter, r *http.Request) {
	rows := s.store.ListPayments()
	out := make([]paymentEntryResponse, 0, len(rows))
	for _, p := range rows {
		out = append(out, paymentEntryResponse{
			ID:          p.ID,
			Provider:    p.Provider,
			Amount:      p.Amount,
			Currency:    p.Currency,
			Status:      p.Status,
			Days:        p.Days,
			Description: p.Description,
			CreatedAt:   formatTime(p.CreatedAt),
			PaidAt:      formatTime(p.PaidAt),
		})
	}
	// Always a list, never null: a null here would make the client special-case
	// "no payments yet" separately from "empty list".
	writeJSON(w, http.StatusOK, map[string]any{"payments": out})
}
