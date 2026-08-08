package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/billing"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

// ─── Create promo (admin) ────────────────────────────────────────────

type promoCreateReq struct {
	Code     string `json:"code"`       // optional — auto-generated if empty
	Type     string `json:"type"`       // "days" | "balance"
	Value    int    `json:"value"`      // days or rubles
	MaxUses  int    `json:"max_uses"`   // 0 = unlimited
	ExpireDays int  `json:"expire_days"` // 0 = never
}

// handlePromoCreate creates a new promo code.
// POST /v1/promo/create
func (s *Server) handlePromoCreate(w http.ResponseWriter, r *http.Request) {
	var req promoCreateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.Type != "days" && req.Type != "balance" {
		writeError(w, http.StatusBadRequest, "type must be 'days' or 'balance'")
		return
	}
	if req.Value <= 0 {
		writeError(w, http.StatusBadRequest, "value must be positive")
		return
	}

	code := billing.NormalizePromoCode(req.Code)
	if code == "" {
		code = billing.GeneratePromoCode()
	}

	// Check for duplicate
	if existing := s.store.GetPromo(code); existing != nil {
		writeError(w, http.StatusConflict, "promo code already exists")
		return
	}

	entry := store.PromoEntry{
		Code:      code,
		Type:      req.Type,
		Value:     req.Value,
		MaxUses:   req.MaxUses,
		CreatedAt: time.Now().UTC(),
		Active:    true,
	}
	if req.ExpireDays > 0 {
		entry.ExpiresAt = time.Now().UTC().Add(time.Duration(req.ExpireDays) * 24 * time.Hour)
	}

	if err := s.store.AddPromo(entry); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, entry)
}

// ─── List promos (admin) ─────────────────────────────────────────────

// handlePromoList returns all promo codes.
// GET /v1/promo/list
func (s *Server) handlePromoList(w http.ResponseWriter, _ *http.Request) {
	promos := s.store.ListPromos()
	writeJSON(w, http.StatusOK, promos)
}

// ─── Redeem promo ────────────────────────────────────────────────────

type promoRedeemReq struct {
	Code string `json:"code"`
}

type promoRedeemResp struct {
	Success bool   `json:"success"`
	Message string `json:"message"`
	Type    string `json:"type,omitempty"`
	Value   int    `json:"value,omitempty"`
}

// handlePromoRedeem redeems a promo code for the linked user.
// POST /v1/promo/redeem
func (s *Server) handlePromoRedeem(w http.ResponseWriter, r *http.Request) {
	var req promoRedeemReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	code := billing.NormalizePromoCode(req.Code)
	if code == "" {
		writeError(w, http.StatusBadRequest, "code is required")
		return
	}

	// Check linked account
	account := s.store.GetAccount()
	if account.TelegramID == 0 || account.Username == "" {
		writeError(w, http.StatusForbidden, "no linked account — link via Telegram bot first")
		return
	}

	// Look up promo
	entry := s.store.GetPromo(code)
	if entry == nil {
		writeJSON(w, http.StatusOK, promoRedeemResp{
			Success: false,
			Message: "Промокод не найден",
		})
		return
	}

	// Validate
	promo := &billing.Promo{
		Code:      entry.Code,
		Type:      entry.Type,
		Value:     entry.Value,
		MaxUses:   entry.MaxUses,
		UsedCount: entry.UsedCount,
		ExpiresAt: entry.ExpiresAt,
		Active:    entry.Active,
	}
	if err := billing.ValidatePromo(promo); err != nil {
		msg := "Промокод недействителен"
		switch {
		case strings.Contains(err.Error(), "expired"):
			msg = "Промокод истек"
		case strings.Contains(err.Error(), "inactive"):
			msg = "Промокод деактивирован"
		case strings.Contains(err.Error(), "limit"):
			msg = "Лимит использований исчерпан"
		}
		writeJSON(w, http.StatusOK, promoRedeemResp{
			Success: false,
			Message: msg,
		})
		return
	}

	// Check per-user uniqueness
	if s.store.HasRedeemed(code, account.TelegramID) {
		writeJSON(w, http.StatusOK, promoRedeemResp{
			Success: false,
			Message: "Вы уже использовали этот промокод",
		})
		return
	}

	// Apply promo
	switch entry.Type {
	case "days":
		if err := s.billing.ExtendUserSubscription(r.Context(), account.Username, entry.Value); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to extend subscription: "+err.Error())
			return
		}
	case "balance":
		// TODO: credit balance when balance system is implemented
	}

	// Record redemption
	_ = s.store.IncrementPromoUsage(code)
	_ = s.store.AddRedemption(store.RedemptionEntry{
		Code:       code,
		Username:   account.Username,
		TelegramID: account.TelegramID,
		RedeemedAt: time.Now().UTC(),
	})

	writeJSON(w, http.StatusOK, promoRedeemResp{
		Success: true,
		Message: "Промокод активирован",
		Type:    entry.Type,
		Value:   entry.Value,
	})
}
