package api

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"

	"github.com/pupspochta-cpu/mosaicvpn/internal/billing"
	"github.com/pupspochta-cpu/mosaicvpn/internal/logx"
)

type lavaCreateReq struct {
	Amount      float64 `json:"amount"`
	Currency    string  `json:"currency"`
	OrderID     string  `json:"order_id"`
	Description string  `json:"description"`
}

type lavaCreateResp struct {
	PaymentID  string  `json:"payment_id"`
	OrderID    string  `json:"order_id"`
	Amount     float64 `json:"amount"`
	Currency   string  `json:"currency"`
	Status     string  `json:"status"`
	PaymentURL string  `json:"payment_url"`
}

// handleLavaCreate creates a Lava payment.
// POST /v1/billing/lava/create
func (s *Server) handleLavaCreate(w http.ResponseWriter, r *http.Request) {
	var req lavaCreateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.Amount <= 0 {
		writeError(w, http.StatusBadRequest, "amount must be positive")
		return
	}
	if req.OrderID == "" {
		writeError(w, http.StatusBadRequest, "order_id required")
		return
	}

	payment, err := s.lava.CreatePayment(r.Context(), req.Amount, req.Currency, req.OrderID, req.Description)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, lavaCreateResp{
		PaymentID:  payment.ID,
		OrderID:    payment.OrderID,
		Amount:     payment.Amount,
		Currency:   payment.Currency,
		Status:     payment.Status,
		PaymentURL: payment.PaymentURL,
	})
}

type lavaStatusResp struct {
	PaymentID string  `json:"payment_id"`
	OrderID   string  `json:"order_id"`
	Amount    float64 `json:"amount"`
	Currency  string  `json:"currency"`
	Status    string  `json:"status"`
}

// handleLavaStatus gets the status of a Lava payment.
// GET /v1/billing/lava/status/{id}
func (s *Server) handleLavaStatus(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		id = r.URL.Query().Get("id")
	}
	if id == "" {
		writeError(w, http.StatusBadRequest, "payment id required")
		return
	}

	payment, err := s.lava.GetPaymentStatus(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, lavaStatusResp{
		PaymentID: payment.ID,
		OrderID:   payment.OrderID,
		Amount:    payment.Amount,
		Currency:  payment.Currency,
		Status:    payment.Status,
	})
}

// handleLavaWebhook processes incoming webhooks from Lava.
// POST /v1/billing/lava/webhook
func (s *Server) handleLavaWebhook(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "failed to read body")
		return
	}

	sig := r.Header.Get("Signature")
	if sig == "" {
		sig = r.Header.Get("Authorization")
		if strings.HasPrefix(sig, "Bearer ") {
			sig = ""
		}
	}

	valid, err := s.lava.VerifyWebhook(body, sig)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !valid {
		writeError(w, http.StatusUnauthorized, "invalid webhook signature")
		return
	}

	var payload struct {
		ID      string  `json:"id"`
		OrderID string  `json:"order_id"`
		Status  string  `json:"status"`
		Amount  float64 `json:"amount"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json payload")
		return
	}

	logx.Info("lava webhook received",
		"payment_id", payload.ID,
		"order_id", payload.OrderID,
		"status", payload.Status,
		"amount", payload.Amount,
	)
	if payload.Status == billing.StatusPaid || payload.Status == "paid" {
		targetID := payload.ID
		if targetID == "" {
			targetID = payload.OrderID
		}
		if targetID != "" {
			if err := s.lava.MarkPaid(r.Context(), targetID, payload.Status); err != nil {
				writeError(w, http.StatusInternalServerError, err.Error())
				return
			}
		}
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
