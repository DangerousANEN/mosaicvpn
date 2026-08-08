package api_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/billing"
)

func TestLavaAPILifecycle(t *testing.T) {
	srv, _, hs := newTestServer(t, nil)

	// 1. POST /v1/billing/lava/create with amount 500 RUB order_id order_123 -> 200
	createPayload := map[string]interface{}{
		"amount":   500,
		"currency": "RUB",
		"order_id": "order_123",
	}
	bodyBytes, err := json.Marshal(createPayload)
	if err != nil {
		t.Fatalf("failed to marshal create request: %v", err)
	}

	req, err := http.NewRequestWithContext(context.Background(), "POST", hs.URL+"/v1/billing/lava/create", bytes.NewReader(bodyBytes))
	if err != nil {
		t.Fatalf("failed to create request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+srv.Token())
	req.Header.Set("Content-Type", "application/json")

	resp, err := hs.Client().Do(req)
	if err != nil {
		t.Fatalf("POST /v1/billing/lava/create failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 from create, got %d", resp.StatusCode)
	}

	var createResp struct {
		PaymentID  string  `json:"payment_id"`
		OrderID    string  `json:"order_id"`
		Amount     float64 `json:"amount"`
		Currency   string  `json:"currency"`
		Status     string  `json:"status"`
		PaymentURL string  `json:"payment_url"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&createResp); err != nil {
		t.Fatalf("failed to decode create response: %v", err)
	}

	if createResp.PaymentID == "" {
		t.Fatal("expected non-empty payment_id")
	}
	if createResp.Status != "pending" {
		t.Fatalf("expected status pending, got %s", createResp.Status)
	}
	if createResp.PaymentURL == "" {
		t.Fatal("expected non-empty payment_url")
	}

	paymentID := createResp.PaymentID

	// 2. GET /v1/billing/lava/status/{payment_id} -> 200 and status pending
	reqStatus, err := http.NewRequestWithContext(context.Background(), "GET", hs.URL+"/v1/billing/lava/status/"+paymentID, nil)
	if err != nil {
		t.Fatalf("failed to create status request: %v", err)
	}
	reqStatus.Header.Set("Authorization", "Bearer "+srv.Token())

	respStatus, err := hs.Client().Do(reqStatus)
	if err != nil {
		t.Fatalf("GET /v1/billing/lava/status failed: %v", err)
	}
	defer respStatus.Body.Close()

	if respStatus.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 from status, got %d", respStatus.StatusCode)
	}

	var statusResp struct {
		PaymentID string `json:"payment_id"`
		Status    string `json:"status"`
	}
	if err := json.NewDecoder(respStatus.Body).Decode(&statusResp); err != nil {
		t.Fatalf("failed to decode status response: %v", err)
	}
	if statusResp.Status != "pending" {
		t.Fatalf("expected status pending, got %s", statusResp.Status)
	}

	// 3. POST /v1/billing/lava/webhook with JSON body containing id and status paid and a valid signature header -> 200
	webhookPayload := map[string]interface{}{
		"id":       paymentID,
		"order_id": "order_123",
		"status":   "paid",
		"amount":   500,
	}
	webhookBytes, err := json.Marshal(webhookPayload)
	if err != nil {
		t.Fatalf("failed to marshal webhook payload: %v", err)
	}

	reqWebhook, err := http.NewRequestWithContext(context.Background(), "POST", hs.URL+"/v1/billing/lava/webhook", bytes.NewReader(webhookBytes))
	if err != nil {
		t.Fatalf("failed to create webhook request: %v", err)
	}
	reqWebhook.Header.Set("Authorization", "Bearer "+srv.Token())
	reqWebhook.Header.Set("Signature", "valid_signature")
	reqWebhook.Header.Set("Content-Type", "application/json")

	respWebhook, err := hs.Client().Do(reqWebhook)
	if err != nil {
		t.Fatalf("POST /v1/billing/lava/webhook failed: %v", err)
	}
	defer respWebhook.Body.Close()

	if respWebhook.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 from webhook, got %d", respWebhook.StatusCode)
	}

	// 4. GET /v1/billing/lava/status/{payment_id} again -> 200 and status now paid
	reqStatusPaid, err := http.NewRequestWithContext(context.Background(), "GET", hs.URL+"/v1/billing/lava/status/"+paymentID, nil)
	if err != nil {
		t.Fatalf("failed to create status request: %v", err)
	}
	reqStatusPaid.Header.Set("Authorization", "Bearer "+srv.Token())

	respStatusPaid, err := hs.Client().Do(reqStatusPaid)
	if err != nil {
		t.Fatalf("GET /v1/billing/lava/status after webhook failed: %v", err)
	}
	defer respStatusPaid.Body.Close()

	if respStatusPaid.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 from status after webhook, got %d", respStatusPaid.StatusCode)
	}

	var statusPaidResp struct {
		PaymentID string `json:"payment_id"`
		Status    string `json:"status"`
	}
	if err := json.NewDecoder(respStatusPaid.Body).Decode(&statusPaidResp); err != nil {
		t.Fatalf("failed to decode status response after webhook: %v", err)
	}
	if statusPaidResp.Status != "paid" {
		t.Fatalf("expected status paid, got %s", statusPaidResp.Status)
	}

	// 5. POST create with amount 0 -> 400, and with missing order_id -> 400
	createZeroBody, _ := json.Marshal(map[string]interface{}{
		"amount":   0,
		"currency": "RUB",
		"order_id": "order_456",
	})
	reqZero, _ := http.NewRequestWithContext(context.Background(), "POST", hs.URL+"/v1/billing/lava/create", bytes.NewReader(createZeroBody))
	reqZero.Header.Set("Authorization", "Bearer "+srv.Token())
	reqZero.Header.Set("Content-Type", "application/json")
	respZero, err := hs.Client().Do(reqZero)
	if err != nil {
		t.Fatalf("POST /v1/billing/lava/create with amount 0 failed: %v", err)
	}
	defer respZero.Body.Close()
	if respZero.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 for amount 0, got %d", respZero.StatusCode)
	}

	createNoOrderBody, _ := json.Marshal(map[string]interface{}{
		"amount":   500,
		"currency": "RUB",
	})
	reqNoOrder, _ := http.NewRequestWithContext(context.Background(), "POST", hs.URL+"/v1/billing/lava/create", bytes.NewReader(createNoOrderBody))
	reqNoOrder.Header.Set("Authorization", "Bearer "+srv.Token())
	reqNoOrder.Header.Set("Content-Type", "application/json")
	respNoOrder, err := hs.Client().Do(reqNoOrder)
	if err != nil {
		t.Fatalf("POST /v1/billing/lava/create with missing order_id failed: %v", err)
	}
	defer respNoOrder.Body.Close()
	if respNoOrder.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 for missing order_id, got %d", respNoOrder.StatusCode)
	}

	// 6. POST webhook with signature header 'invalid' -> 401
	reqInvalidSig, _ := http.NewRequestWithContext(context.Background(), "POST", hs.URL+"/v1/billing/lava/webhook", bytes.NewReader(webhookBytes))
	reqInvalidSig.Header.Set("Authorization", "Bearer "+srv.Token())
	reqInvalidSig.Header.Set("Signature", "invalid")
	reqInvalidSig.Header.Set("Content-Type", "application/json")
	respInvalidSig, err := hs.Client().Do(reqInvalidSig)
	if err != nil {
		t.Fatalf("POST /v1/billing/lava/webhook with invalid signature failed: %v", err)
	}
	defer respInvalidSig.Body.Close()
	if respInvalidSig.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 for invalid signature, got %d", respInvalidSig.StatusCode)
	}
}
func TestLavaAPIWebhookFallbackOrderID(t *testing.T) {
	srv, _, hs := newTestServer(t, nil)

	createPayload := map[string]interface{}{
		"amount":   500,
		"currency": "RUB",
		"order_id": "order_fallback_999",
	}
	bodyBytes, _ := json.Marshal(createPayload)

	req, _ := http.NewRequestWithContext(context.Background(), "POST", hs.URL+"/v1/billing/lava/create", bytes.NewReader(bodyBytes))
	req.Header.Set("Authorization", "Bearer "+srv.Token())
	req.Header.Set("Content-Type", "application/json")

	resp, err := hs.Client().Do(req)
	if err != nil {
		t.Fatalf("create failed: %v", err)
	}
	var createResp struct {
		PaymentID string `json:"payment_id"`
	}
	json.NewDecoder(resp.Body).Decode(&createResp)
	resp.Body.Close()

	// Send webhook without ID, only order_id
	webhookPayload := map[string]interface{}{
		"id":       "",
		"order_id": "order_fallback_999",
		"status":   "paid",
	}
	webhookBytes, _ := json.Marshal(webhookPayload)
	reqWebhook, _ := http.NewRequestWithContext(context.Background(), "POST", hs.URL+"/v1/billing/lava/webhook", bytes.NewReader(webhookBytes))
	reqWebhook.Header.Set("Authorization", "Bearer "+srv.Token())
	reqWebhook.Header.Set("Signature", "valid_signature")
	reqWebhook.Header.Set("Content-Type", "application/json")

	respWebhook, err := hs.Client().Do(reqWebhook)
	if err != nil {
		t.Fatalf("webhook failed: %v", err)
	}
	respWebhook.Body.Close()
	if respWebhook.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 from webhook, got %d", respWebhook.StatusCode)
	}

	// Verify status updated to paid via GET status using paymentID
	reqStatus, _ := http.NewRequestWithContext(context.Background(), "GET", hs.URL+"/v1/billing/lava/status/"+createResp.PaymentID, nil)
	reqStatus.Header.Set("Authorization", "Bearer "+srv.Token())
	respStatus, err := hs.Client().Do(reqStatus)
	if err != nil {
		t.Fatalf("status failed: %v", err)
	}
	defer respStatus.Body.Close()

	var statusResp struct {
		Status string `json:"status"`
	}
	json.NewDecoder(respStatus.Body).Decode(&statusResp)
	if statusResp.Status != "paid" {
		t.Fatalf("expected status paid via order_id fallback, got %s", statusResp.Status)
	}
}

func TestLavaAPISetLavaProvider(t *testing.T) {
	srv, _, hs := newTestServer(t, nil)
	mock := billing.NewLavaMockProvider()
	srv.SetLavaProvider(mock)

	reqStatus, _ := http.NewRequestWithContext(context.Background(), "GET", hs.URL+"/v1/billing/lava/status/nonexistent", nil)
	reqStatus.Header.Set("Authorization", "Bearer "+srv.Token())

	resp, err := hs.Client().Do(reqStatus)
	if err != nil {
		t.Fatalf("status failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404 for nonexistent payment on custom provider, got %d", resp.StatusCode)
	}
}
