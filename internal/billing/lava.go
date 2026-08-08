package billing

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"
)

// Payment statuses
const (
	StatusPending = "pending"
	StatusPaid    = "paid"
	StatusFailed  = "failed"
	StatusExpired = "expired"
)

// Payment represents a Lava payment object.
type Payment struct {
	ID         string    `json:"id"`
	OrderID    string    `json:"order_id"`
	Amount     float64   `json:"amount"`
	Currency   string    `json:"currency"`
	Status     string    `json:"status"` // pending | paid | failed | expired
	PaymentURL string    `json:"payment_url"`
	CreatedAt  time.Time `json:"created_at"`
}

type PaymentProvider interface {
	CreatePayment(ctx context.Context, amount float64, currency, orderID, description string) (*Payment, error)
	GetPaymentStatus(ctx context.Context, paymentID string) (*Payment, error)
	VerifyWebhook(body []byte, signature string) (bool, error)
	MarkPaid(ctx context.Context, paymentID, status string) error
}

// NewLavaProvider initializes a PaymentProvider based on mode or LAVA_MODE environment variable.
// Valid modes: "mock", "live". Default is "mock".
func NewLavaProvider() PaymentProvider {
	mode := os.Getenv("LAVA_MODE")
	if mode == "live" {
		return NewLavaLiveProvider()
	}
	return NewLavaMockProvider()
}

// ──────────────────── LavaMockProvider ─────────────────────

// LavaMockProvider is a thread-safe mock provider for testing and development.
type LavaMockProvider struct {
	mu       sync.RWMutex
	payments map[string]*Payment
	seq      int64
}

// NewLavaMockProvider creates a new LavaMockProvider instance.
func NewLavaMockProvider() *LavaMockProvider {
	return &LavaMockProvider{
		payments: make(map[string]*Payment),
	}
}

func (m *LavaMockProvider) CreatePayment(ctx context.Context, amount float64, currency, orderID, description string) (*Payment, error) {
	if amount <= 0 {
		return nil, fmt.Errorf("lava mock: amount must be positive, got %f", amount)
	}
	if currency == "" {
		currency = "RUB"
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	m.seq++
	id := fmt.Sprintf("lava_mock_%d_%s", m.seq, orderID)
	p := &Payment{
		ID:         id,
		OrderID:    orderID,
		Amount:     amount,
		Currency:   currency,
		Status:     StatusPending,
		PaymentURL: fmt.Sprintf("https://mock.lava.ru/pay/%s", id),
		CreatedAt:  time.Now(),
	}
	m.payments[id] = p
	return p, nil
}

func (m *LavaMockProvider) GetPaymentStatus(ctx context.Context, paymentID string) (*Payment, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	p, exists := m.payments[paymentID]
	if !exists {
		return nil, fmt.Errorf("lava mock: payment %s not found", paymentID)
	}
	cp := *p
	return &cp, nil
}

func (m *LavaMockProvider) VerifyWebhook(body []byte, signature string) (bool, error) {
	if signature == "invalid_signature" || signature == "invalid" || signature == "" {
		return false, nil
	}
	return true, nil
}

// SetPaid manually sets a payment status to paid (for tests).
func (m *LavaMockProvider) SetPaid(paymentID string) error {
	return m.MarkPaid(context.Background(), paymentID, StatusPaid)
}

// MarkPaid sets a payment status in mock provider.
func (m *LavaMockProvider) MarkPaid(ctx context.Context, paymentID, status string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if status == "" {
		status = StatusPaid
	}

	if p, exists := m.payments[paymentID]; exists {
		p.Status = status
		return nil
	}

	for _, p := range m.payments {
		if p.OrderID == paymentID {
			p.Status = status
			return nil
		}
	}

	return fmt.Errorf("lava mock: payment %s not found", paymentID)
}

// ──────────────────── LavaLiveProvider ─────────────────────

// LavaLiveProvider implements PaymentProvider for production lava.ru API.
//
// TODO: Future implementation details for Lava API (https://dev.lava.ru / https://api.lava.ru):
// 1. Create Invoice:
//    POST https://api.lava.ru/business/invoice/create
//    Headers:
//      Accept: application/json
//      Content-Type: application/json
//      Signature: HMAC-SHA256 of JSON request body using LAVA_SECRET_KEY
//    Body JSON:
//      {
//        "sum": amount,
//        "orderId": orderID,
//        "shopId": LAVA_SHOP_ID,
//        "comment": description,
//        "successUrl": returnURL,
//        "failUrl": failURL
//      }
// 2. Get Invoice Status:
//    POST https://api.lava.ru/business/invoice/status
//    Headers: Signature header with HMAC-SHA256 of JSON request body
//    Body JSON:
//      {
//        "shopId": LAVA_SHOP_ID,
//        "orderId": orderID / "invoiceId": paymentID
//      }
// 3. Webhook verification:
//    Lava sends POST callback to registered webhook URL.
//    Verification requires generating HMAC-SHA256 hash of raw HTTP request body with LAVA_SECRET_KEY
//    and comparing it against signature header ("Authorization" or "Signature").
type LavaLiveProvider struct {
	apiKey    string
	shopID    string
	secretKey string
}

// NewLavaLiveProvider initializes LavaLiveProvider using environment variables.
func NewLavaLiveProvider() *LavaLiveProvider {
	return &LavaLiveProvider{
		apiKey:    os.Getenv("LAVA_API_KEY"),
		shopID:    os.Getenv("LAVA_SHOP_ID"),
		secretKey: os.Getenv("LAVA_SECRET_KEY"),
	}
}

func (l *LavaLiveProvider) configured() bool {
	return l.apiKey != ""
}

func (l *LavaLiveProvider) CreatePayment(ctx context.Context, amount float64, currency, orderID, description string) (*Payment, error) {
	if !l.configured() {
		return nil, errors.New("lava live provider not configured: set LAVA_API_KEY")
	}
	return nil, errors.New("lava live provider not fully implemented")
}

func (l *LavaLiveProvider) GetPaymentStatus(ctx context.Context, paymentID string) (*Payment, error) {
	if !l.configured() {
		return nil, errors.New("lava live provider not configured: set LAVA_API_KEY")
	}
	return nil, errors.New("lava live provider not fully implemented")
}

func (l *LavaLiveProvider) VerifyWebhook(body []byte, signature string) (bool, error) {
	if !l.configured() {
		return false, errors.New("lava live provider not configured: set LAVA_API_KEY")
	}
	if l.secretKey == "" {
		return false, errors.New("lava live provider secret key not configured: set LAVA_SECRET_KEY")
	}
	mac := hmac.New(sha256.New, []byte(l.secretKey))
	mac.Write(body)
	expectedSignature := hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(signature), []byte(expectedSignature)), nil
}
func (l *LavaLiveProvider) MarkPaid(ctx context.Context, paymentID, status string) error {
	if !l.configured() {
		return errors.New("lava live provider not configured: set LAVA_API_KEY")
	}
	return errors.New("lava live provider not fully implemented")
}
