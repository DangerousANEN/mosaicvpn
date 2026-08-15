package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/billing"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

// billingProfileResponse is the payload returned to the Flutter client.
// It merges the Remnawave user record with traffic counters.
type billingProfileResponse struct {
	Linked              bool   `json:"linked"`
	Username            string `json:"username,omitempty"`
	ShortUUID           string `json:"short_uuid,omitempty"`
	Status              string `json:"status,omitempty"`
	TelegramID          int64  `json:"telegram_id,omitempty"`
	Tag                 string `json:"tag,omitempty"`
	Email               string `json:"email,omitempty"`
	TrafficLimitBytes   int64  `json:"traffic_limit_bytes,omitempty"`
	UsedTrafficBytes    int64  `json:"used_traffic_bytes,omitempty"`
	ExpireAt            string `json:"expire_at,omitempty"` // RFC3339
	ExpireDaysRemaining int    `json:"expire_days_remaining,omitempty"`
	Description         string `json:"description,omitempty"`
}

// handleBillingProfile returns the linked Mosaic service profile.
//
// GET /v1/billing/profile
func (s *Server) handleBillingProfile(w http.ResponseWriter, r *http.Request) {
	acct := s.store.GetAccount()
	if acct.TelegramID == 0 && acct.DirectToken == "" {
		writeJSON(w, http.StatusOK, billingProfileResponse{Linked: false})
		return
	}
	if acct.TelegramID == 0 {
		writeJSON(w, http.StatusOK, billingProfileResponse{Linked: true, Username: acct.Username, Email: acct.Email, ExpireAt: formatTime(acct.ExpireAt)})
		return
	}
	if s.billing == nil {
		writeJSON(w, http.StatusOK, billingProfileResponse{
			Linked:     true,
			Username:   acct.Username,
			TelegramID: acct.TelegramID,
			ExpireAt:   formatTime(acct.ExpireAt),
		})
		return
	}
	user, err := s.billing.GetUserByTelegramID(r.Context(), acct.TelegramID)
	if err != nil {
		if errors.Is(err, billing.ErrUserNotFound) {
			writeJSON(w, http.StatusOK, billingProfileResponse{Linked: false})
			return
		}
		writeError(w, http.StatusBadGateway, "remnawave: "+err.Error())
		return
	}
	resp := billingProfileResponse{
		Linked:              true,
		Username:            user.Username,
		ShortUUID:           user.ShortUUID,
		Status:              user.Status,
		TelegramID:          user.TelegramID,
		Tag:                 user.Tag,
		Email:               user.Email,
		TrafficLimitBytes:   user.TrafficLimitBytes,
		ExpireAt:            formatTime(user.ExpireAt),
		Description:         user.Description,
		ExpireDaysRemaining: daysUntil(user.ExpireAt),
	}
	// Best-effort traffic fetch; a traffic failure does not fail the whole
	// profile request.
	if traffic, err := s.billing.GetUserTraffic(r.Context(), user.UUID); err == nil && traffic != nil {
		resp.UsedTrafficBytes = traffic.UsedTrafficBytes
	}
	// Cache for offline display. SessionToken must be carried over: writing
	// a zero value here would silently unlink the account on the next
	// profile refresh, because the link check keys off a non-empty token.
	_ = s.store.SetAccount(store.Account{
		TelegramID:    acct.TelegramID,
		SessionToken:  acct.SessionToken,
		DirectToken:   acct.DirectToken,
		DirectFeedURL: acct.DirectFeedURL,
		Username:      user.Username,
		Email:         acct.Email,
		ExpireAt:      user.ExpireAt,
	})
	writeJSON(w, http.StatusOK, resp)
}

// linkRequest binds the linking payload from the Flutter client.
type linkRequest struct {
	TelegramID   int64  `json:"telegram_id"`
	SessionToken string `json:"session_token"` // issued by @mosaicvpnbot
}

// handleBillingLink stores the Telegram account link. The Flutter client
// receives a session token via a bot deeplink; it posts it here.
//
// POST /v1/billing/link   { "telegram_id": 123, "session_token": "..." }
func (s *Server) handleBillingLink(w http.ResponseWriter, r *http.Request) {
	var req linkRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body: "+err.Error())
		return
	}
	if req.TelegramID == 0 || req.SessionToken == "" {
		writeError(w, http.StatusBadRequest, "telegram_id and session_token required")
		return
	}
	// TODO: verify session_token with the bot bridge when available.
	// For now the token is stored as-is; the daemon trusts the Flutter
	// client which obtained it from the authenticated Telegram bot.
	if err := s.store.SetAccount(store.Account{
		TelegramID:   req.TelegramID,
		SessionToken: req.SessionToken,
	}); err != nil {
		writeError(w, http.StatusInternalServerError, "store: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleBillingUnlink clears the account link.
//
// POST /v1/billing/unlink
func (s *Server) handleBillingUnlink(w http.ResponseWriter, r *http.Request) {
	// The direct feed URL contains a per-device credential. Remove it with the
	// account record so another person using this OS account cannot reuse a
	// previous user's subscription after logout. Manually added subscriptions
	// remain intact.
	if err := s.store.DeleteSubscription("mosaic-direct"); err != nil {
		writeError(w, http.StatusInternalServerError, "remove direct subscription: "+err.Error())
		return
	}
	if err := s.store.ClearAccount(); err != nil {
		writeError(w, http.StatusInternalServerError, "store: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// topupRequest creates a CryptoBot invoice.
type topupRequest struct {
	Amount      float64 `json:"amount"`      // USDT
	Description string  `json:"description"` // optional
	Days        int     `json:"days"`        // days to add on payment
}

// topupResponse is returned after creating an invoice.
type topupResponse struct {
	InvoiceID int64  `json:"invoice_id"`
	PayURL    string `json:"pay_url"`
	Amount    string `json:"amount"`
	Asset     string `json:"asset"`
}

// handleBillingTopup creates a CryptoBot invoice for subscription top-up.
//
// POST /v1/billing/topup   { "amount": 5.0, "days": 30, "description": "..." }
func (s *Server) handleBillingTopup(w http.ResponseWriter, r *http.Request) {
	acct := s.store.GetAccount()
	if acct.TelegramID == 0 {
		writeError(w, http.StatusForbidden, "no linked account")
		return
	}
	if s.billing == nil {
		writeError(w, http.StatusServiceUnavailable, "billing not configured")
		return
	}
	var req topupRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body: "+err.Error())
		return
	}
	if req.Amount <= 0 {
		writeError(w, http.StatusBadRequest, "amount must be positive")
		return
	}
	desc := req.Description
	if desc == "" {
		desc = "MosaicVPN subscription top-up"
		if req.Days > 0 {
			desc += " — " + strconv.Itoa(req.Days) + " days"
		}
	}
	inv, err := s.billing.CreateInvoice(r.Context(), req.Amount, desc)
	if err != nil {
		writeError(w, http.StatusBadGateway, "cryptobot: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, topupResponse{
		InvoiceID: inv.InvoiceID,
		PayURL:    inv.PayURL,
		Amount:    inv.Amount,
		Asset:     inv.Asset,
	})
}

// handleBillingTopupStatus checks the status of a CryptoBot invoice.
//
// GET /v1/billing/topup/{id}
func (s *Server) handleBillingTopupStatus(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil {
		writeError(w, http.StatusServiceUnavailable, "billing not configured")
		return
	}
	idStr := r.PathValue("id")
	invoiceID, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || invoiceID == 0 {
		writeError(w, http.StatusBadRequest, "invalid invoice id")
		return
	}
	status, err := s.billing.CheckInvoice(r.Context(), invoiceID)
	if err != nil {
		writeError(w, http.StatusBadGateway, "cryptobot: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"invoice_id": invoiceID,
		"status":     status,
	})
}

// ─── helpers ───

func formatTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

func daysUntil(t time.Time) int {
	if t.IsZero() {
		return 0
	}
	d := time.Until(t).Hours() / 24
	if d < 0 {
		return 0
	}
	return int(d)
}
