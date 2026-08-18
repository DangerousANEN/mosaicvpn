package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
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
	// SubscriptionID is optional for legacy client login. When present, the
	// redeemed account may be attached only to that existing matching URL row.
	SubscriptionID string `json:"subscription_id,omitempty"`
}

type emailLoginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

const mosaicProviderSubscriptionID = "provider-mosaicvpn-primary"

// mosaicProviderSubscription builds a user-owned HTTPS feed subscription.
// A compatible MosaicVPN cabinet may be attached through stored account state,
// but the URL itself remains independently refreshable, connectable and
// removable. `mosaic-direct` remains only as a migration alias for old state.
func mosaicProviderSubscription(feedURL string) proto.Subscription {
	return mosaicProviderSubscriptionFor("mosaicvpn-default", "MosaicVPN", feedURL)
}

// mosaicProviderSubscriptionFor builds a stable local URL source for one
// account feed. The account value is used only to derive a local opaque ID; it
// is never persisted in the subscription metadata or exposed in UI/logs.
func mosaicProviderSubscriptionFor(providerAccountID, name, feedURL string) proto.Subscription {
	accountID := strings.TrimSpace(providerAccountID)
	if accountID == "" {
		accountID = "mosaicvpn-default"
	}
	subscriptionID := mosaicProviderSubscriptionID
	if accountID != "mosaicvpn-default" {
		sum := sha256.Sum256([]byte(accountID))
		subscriptionID = "provider-mosaicvpn-" + hex.EncodeToString(sum[:8])
	}
	displayName := strings.TrimSpace(name)
	if displayName == "" {
		displayName = "MosaicVPN"
	}
	return proto.Subscription{
		ID:                     subscriptionID,
		Name:                   displayName,
		URL:                    strings.TrimSpace(feedURL),
		AutoRefresh:            true,
		RefreshIntervalSeconds: 3600,
		Source:                 proto.SubscriptionSourceURL,
		// The manifest remains the only user-visible route catalog. Feed nodes
		// are implementation details and are never rendered in route tables.
		HidePhysicalNodes: true,
	}
}

// handleProviderEnrollment persists a website-authorized provider subscription.
// It must never be folded into handleAddSub: a generic URL import has no proof
// that it owns provider-only cabinet capabilities or Smart Group semantics.
func (s *Server) handleProviderEnrollment(w http.ResponseWriter, r *http.Request) {
	var req proto.ProviderEnrollmentRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid provider enrollment body")
		return
	}
	if strings.TrimSpace(req.ProviderID) != "mosaicvpn" {
		writeError(w, http.StatusBadRequest, "unsupported provider enrollment")
		return
	}
	if strings.TrimSpace(req.ProviderAccountID) == "" {
		writeError(w, http.StatusBadRequest, "provider account identity required")
		return
	}
	feedURL, err := url.Parse(strings.TrimSpace(req.SubscriptionURL))
	if err != nil || feedURL.Scheme != "https" || !strings.EqualFold(feedURL.Host, "sub.zxc1x1.ru") || len(feedURL.Path) <= 1 {
		writeError(w, http.StatusBadRequest, "invalid MosaicVPN subscription URL")
		return
	}

	providerSub := mosaicProviderSubscriptionFor(
		req.ProviderAccountID,
		req.SubscriptionName,
		feedURL.String(),
	)
	// If this URL was already imported manually, keep its local ID and all
	// user-visible ordering. Website enrollment enriches that same source; it
	// must not create a second hidden/provider row or delete the original.
	for _, existing := range s.store.Snapshot().Subscriptions {
		if existing.URL == providerSub.URL {
			providerSub.ID = existing.ID
			if providerSub.Name == "" {
				providerSub.Name = existing.Name
			}
			break
		}
	}

	// The provider exchange happens over HTTPS before this loopback request.
	// Keep a subscription-scoped cabinet binding after refresh succeeds. The
	// legacy global account is updated only for old cabinet clients; the URL row
	// itself remains independently connectable and removable.
	var binding store.Account
	hasBinding := req.SessionToken != "" || req.DirectToken != "" || req.Username != ""
	if hasBinding {
		binding = s.store.GetAccount()
		if req.SessionToken != "" {
			binding.SessionToken = req.SessionToken
		}
		if req.DirectToken != "" {
			binding.DirectToken = req.DirectToken
		}
		binding.DirectFeedURL = providerSub.URL
		if req.Username != "" {
			binding.Username = req.Username
			if strings.Contains(req.Username, "@") {
				binding.Email = req.Username
			}
		}
		if err := s.store.SetAccount(binding); err != nil {
			writeError(w, http.StatusInternalServerError, "store provider account: "+err.Error())
			return
		}
	}

	stored, err := s.store.AddOrUpdateSubscription(providerSub)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "store provider subscription: "+err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	if err := s.refresh(ctx, stored); err != nil {
		_ = s.store.MarkSubscriptionError(stored.ID, err.Error())
		writeError(w, http.StatusBadGateway, "provider subscription refresh: "+err.Error())
		return
	}
	if hasBinding {
		if err := s.store.SetCabinetBinding(stored.ID, binding); err != nil {
			writeError(w, http.StatusInternalServerError, "store cabinet binding: "+err.Error())
			return
		}
	}
	for _, current := range s.store.Snapshot().Subscriptions {
		if current.ID == stored.ID {
			writeJSON(w, http.StatusOK, current)
			return
		}
	}
	writeJSON(w, http.StatusOK, stored)
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
			linked := store.Account{
				TelegramID:    res.TelegramID,
				SessionToken:  res.SessionToken,
				DirectToken:   res.DirectToken,
				DirectFeedURL: res.DirectFeedURL,
				Username:      res.Username,
			}
			if serr := s.store.SetAccount(linked); serr != nil {
				writeError(w, http.StatusInternalServerError, "store: "+serr.Error())
				return
			}
			if res.DirectFeedURL != "" && strings.TrimSpace(req.SubscriptionID) != "" {
				var selected *proto.Subscription
				for _, sub := range s.store.Snapshot().Subscriptions {
					if sub.ID == req.SubscriptionID {
						copy := sub
						selected = &copy
						break
					}
				}
				if selected == nil {
					writeError(w, http.StatusNotFound, "selected subscription not found")
					return
				}
				if strings.TrimSpace(selected.URL) != strings.TrimSpace(res.DirectFeedURL) {
					writeError(w, http.StatusConflict, "code belongs to another subscription")
					return
				}
				if serr := s.refresh(r.Context(), *selected); serr != nil {
					writeError(w, http.StatusBadGateway, "subscription fetch: "+serr.Error())
					return
				}
				if serr := s.store.SetCabinetBinding(selected.ID, linked); serr != nil {
					writeError(w, http.StatusInternalServerError, "store cabinet binding: "+serr.Error())
					return
				}
			} else if res.DirectFeedURL != "" {
				// Legacy behavior: create a URL source only when the caller did not
				// select an existing source to attach.
				directSub := mosaicProviderSubscription(res.DirectFeedURL)
				stored, serr := s.store.AddOrUpdateSubscription(directSub)
				if serr != nil {
					writeError(w, http.StatusInternalServerError, "store direct subscription: "+serr.Error())
					return
				}
				if serr := s.refresh(r.Context(), stored); serr != nil {
					writeError(w, http.StatusBadGateway, "direct subscription fetch: "+serr.Error())
					return
				}
				if serr := s.store.SetCabinetBinding(stored.ID, linked); serr != nil {
					writeError(w, http.StatusInternalServerError, "store cabinet binding: "+serr.Error())
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
