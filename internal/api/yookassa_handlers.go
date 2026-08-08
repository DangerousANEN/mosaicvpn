package api

import (
	"encoding/json"
	"net/http"

	"github.com/pupspochta-cpu/mosaicvpn/internal/billing"
	"github.com/pupspochta-cpu/mosaicvpn/internal/logx"
)

// ─── YooKassa payment creation ────────────────────────────────────────

type yookassaCreateReq struct {
	Amount      float64 `json:"amount"`       // rubles, e.g. 100
	Description string  `json:"description"`  // human-visible
	ReturnURL   string  `json:"return_url"`   // after payment redirect
	UseSBP      bool    `json:"use_sbp"`      // true → SBP QR code flow
}

type yookassaCreateResp struct {
	PaymentID       string `json:"payment_id"`
	Status          string `json:"status"`
	ConfirmationURL string `json:"confirmation_url,omitempty"` // redirect for card
	QRData          string `json:"qr_data,omitempty"`          // QR code data for SBP
}

// handleYookassaCreate creates a YooKassa payment (card or SBP).
// POST /v1/billing/yookassa/create
func (s *Server) handleYookassaCreate(w http.ResponseWriter, r *http.Request) {
	var req yookassaCreateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.Amount <= 0 {
		writeError(w, http.StatusBadRequest, "amount must be positive")
		return
	}
	if req.ReturnURL == "" && !req.UseSBP {
		req.ReturnURL = "https://sub.zxc1x1.ru/"
	}

	payment, err := s.billing.CreateYookassaPayment(r.Context(), billing.YookassaCreateOpts{
		AmountRUB:   req.Amount,
		Description: req.Description,
		ReturnURL:   req.ReturnURL,
		UseSBP:      req.UseSBP,
		Metadata: map[string]string{
			"source": "mosaicd",
		},
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	resp := yookassaCreateResp{
		PaymentID: payment.ID,
		Status:    payment.Status,
	}
	if payment.Confirmation != nil {
		resp.ConfirmationURL = payment.Confirmation.ConfirmationURL
		resp.QRData = payment.Confirmation.ConfirmationData
	}
	writeJSON(w, http.StatusOK, resp)
}

// ─── YooKassa payment status check ────────────────────────────────────

type yookassaStatusResp struct {
	PaymentID string `json:"payment_id"`
	Status    string `json:"status"` // pending | waiting_for_capture | succeeded | canceled
	Paid      bool   `json:"paid"`
	Amount    string `json:"amount"`
	Currency  string `json:"currency"`
}

// handleYookassaStatus checks the status of a YooKassa payment.
// GET /v1/billing/yookassa/status?payment_id=xxx
func (s *Server) handleYookassaStatus(w http.ResponseWriter, r *http.Request) {
	paymentID := r.URL.Query().Get("payment_id")
	if paymentID == "" {
		writeError(w, http.StatusBadRequest, "payment_id required")
		return
	}

	payment, err := s.billing.GetYookassaPayment(r.Context(), paymentID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, yookassaStatusResp{
		PaymentID: payment.ID,
		Status:    payment.Status,
		Paid:      payment.Paid,
		Amount:    payment.Amount.Value,
		Currency:  payment.Amount.Currency,
	})
}

// ─── YooKassa webhook ────────────────────────────────────────────────

// handleYookassaWebhook receives payment notifications from YooKassa.
// POST /v1/billing/yookassa/webhook
//
// YooKassa sends POST with JSON body:
//
//	{
//	  "type": "notification",
//	  "event": "payment.succeeded",
//	  "object": { ... payment object ... }
//	}
//
// On payment.succeeded: extend user subscription by paid days.
func (s *Server) handleYookassaWebhook(w http.ResponseWriter, r *http.Request) {
	var webhook struct {
		Type   string          `json:"type"`
		Event  string          `json:"event"`
		Object json.RawMessage `json:"object"`
	}
	if err := json.NewDecoder(r.Body).Decode(&webhook); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	if webhook.Event != "payment.succeeded" {
		// Acknowledge non-success events silently.
		writeJSON(w, http.StatusOK, map[string]string{"status": "ignored"})
		return
	}

	var payment billing.YookassaPayment
	if err := json.Unmarshal(webhook.Object, &payment); err != nil {
		writeError(w, http.StatusBadRequest, "invalid payment object: "+err.Error())
		return
	}

	// TODO: Look up user by payment.Metadata["telegram_id"] or similar,
	// calculate days from payment.Amount, extend subscription via
	// s.billing.ExtendUserSubscription(). For now, log and ack.
	logx.Info("yookassa payment succeeded",
		"payment_id", payment.ID,
		"amount", payment.Amount.Value,
		"currency", payment.Amount.Currency,
		"metadata", payment.Metadata,
	)

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
