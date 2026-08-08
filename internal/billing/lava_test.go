package billing

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

func TestLavaMockProvider_FullLifecycle(t *testing.T) {
	provider := NewLavaMockProvider()
	ctx := context.Background()

	// 1. Create payment
	payment, err := provider.CreatePayment(ctx, 500.0, "RUB", "order_123", "Test payment")
	if err != nil {
		t.Fatalf("failed to create payment: %v", err)
	}

	if payment.ID == "" {
		t.Fatal("expected non-empty payment ID")
	}
	if payment.Status != StatusPending {
		t.Fatalf("expected status %s, got %s", StatusPending, payment.Status)
	}
	if payment.PaymentURL == "" {
		t.Fatal("expected non-empty payment URL")
	}

	// 2. Check pending status
	st, err := provider.GetPaymentStatus(ctx, payment.ID)
	if err != nil {
		t.Fatalf("failed to get status: %v", err)
	}
	if st.Status != StatusPending {
		t.Fatalf("expected status %s, got %s", StatusPending, st.Status)
	}

	// 3. Mark paid manually
	if err := provider.SetPaid(payment.ID); err != nil {
		t.Fatalf("failed to set paid: %v", err)
	}

	// 4. Verify status is paid
	stPaid, err := provider.GetPaymentStatus(ctx, payment.ID)
	if err != nil {
		t.Fatalf("failed to get status after paying: %v", err)
	}
	if stPaid.Status != StatusPaid {
		t.Fatalf("expected status %s, got %s", StatusPaid, stPaid.Status)
	}
}

func TestLavaLiveProvider_WithoutKey(t *testing.T) {
	t.Setenv("LAVA_API_KEY", "")
	provider := NewLavaLiveProvider()
	ctx := context.Background()

	_, err := provider.CreatePayment(ctx, 100.0, "RUB", "order_test", "desc")
	if err == nil {
		t.Fatal("expected error when LAVA_API_KEY is not set, got nil")
	}
	expectedMsg := "lava live provider not configured: set LAVA_API_KEY"
	if err.Error() != expectedMsg {
		t.Fatalf("expected error msg %q, got %q", expectedMsg, err.Error())
	}

	_, err = provider.GetPaymentStatus(ctx, "payment_123")
	if err == nil {
		t.Fatal("expected error when LAVA_API_KEY is not set, got nil")
	}
	if err.Error() != expectedMsg {
		t.Fatalf("expected error msg %q, got %q", expectedMsg, err.Error())
	}

	_, err = provider.VerifyWebhook([]byte("{}"), "sig")
	if err == nil {
		t.Fatal("expected error when LAVA_API_KEY is not set, got nil")
	}
	if err.Error() != expectedMsg {
		t.Fatalf("expected error msg %q, got %q", expectedMsg, err.Error())
	}
}

func TestLavaWebhookVerification(t *testing.T) {
	// Mock provider test
	mockProvider := NewLavaMockProvider()
	ok, err := mockProvider.VerifyWebhook([]byte("test_body"), "valid_signature")
	if err != nil {
		t.Fatalf("unexpected error on mock webhook verification: %v", err)
	}
	if !ok {
		t.Fatal("expected true for valid signature in mock provider")
	}

	ok, err = mockProvider.VerifyWebhook([]byte("test_body"), "invalid")
	if err != nil {
		t.Fatalf("unexpected error on mock webhook verification: %v", err)
	}
	if ok {
		t.Fatal("expected false for invalid signature in mock provider")
	}

	// Live provider test with keys
	secretKey := "secret_key_123"
	t.Setenv("LAVA_API_KEY", "test_api_key")
	t.Setenv("LAVA_SECRET_KEY", secretKey)
	liveProvider := NewLavaLiveProvider()

	body := []byte(`{"order_id":"123","status":"paid"}`)

	mac := hmac.New(sha256.New, []byte(secretKey))
	mac.Write(body)
	validSig := hex.EncodeToString(mac.Sum(nil))

	ok, err = liveProvider.VerifyWebhook(body, validSig)
	if err != nil {
		t.Fatalf("unexpected error on live webhook verification: %v", err)
	}
	if !ok {
		t.Fatal("expected webhook verification to succeed with valid signature")
	}

	ok, err = liveProvider.VerifyWebhook(body, "invalid_sig_hex")
	if err != nil {
		t.Fatalf("unexpected error on live webhook verification: %v", err)
	}
	if ok {
		t.Fatal("expected webhook verification to fail with invalid signature")
	}
}
