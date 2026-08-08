package billing

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// YookassaConfig holds credentials for the YooKassa (ЮKassa) payment gateway.
type YookassaConfig struct {
	ShopID    string `json:"shop_id"`    // YooKassa shop ID (numeric string)
	SecretKey string `json:"secret_key"` // YooKassa secret key
	BaseURL   string `json:"base_url"`   // default https://api.yookassa.ru
}

func (y YookassaConfig) configured() bool {
	return y.ShopID != "" && y.SecretKey != ""
}

func (y YookassaConfig) base() string {
	if y.BaseURL != "" {
		return y.BaseURL
	}
	return "https://api.yookassa.ru"
}

// ──────────────────── Payment types ─────────────────────

// YookassaPayment represents a YooKassa payment object (subset of fields).
type YookassaPayment struct {
	ID           string                 `json:"id"`
	Status       string                 `json:"status"` // pending | waiting_for_capture | succeeded | canceled
	Amount       YookassaAmount         `json:"amount"`
	Description  string                 `json:"description,omitempty"`
	Confirmation *YookassaConfirmation  `json:"confirmation,omitempty"`
	CreatedAt    time.Time              `json:"created_at"`
	Paid         bool                   `json:"paid"`
	Metadata     map[string]string      `json:"metadata,omitempty"`
}

// YookassaAmount holds a monetary amount with currency.
type YookassaAmount struct {
	Value    string `json:"value"`    // "100.00"
	Currency string `json:"currency"` // "RUB"
}

// YookassaConfirmation contains the redirect URL for the user to complete payment.
type YookassaConfirmation struct {
	Type            string `json:"type"`                       // "redirect" | "qr"
	ConfirmationURL string `json:"confirmation_url,omitempty"` // redirect URL for user
	ConfirmationData string `json:"confirmation_data,omitempty"` // QR code data (for SBP)
}

// ──────────────────── Create payment ─────────────────────

// YookassaCreateOpts configures a new YooKassa payment.
type YookassaCreateOpts struct {
	AmountRUB    float64           // amount in rubles (e.g. 100.00)
	Description  string            // human-visible description
	ReturnURL    string            // URL to redirect after payment
	Metadata     map[string]string // arbitrary key-value pairs passed through
	UseSBP       bool              // if true, use SBP (СБП) flow with QR code
}

// CreateYookassaPayment creates a YooKassa payment and returns the payment
// object with a confirmation URL (or QR data for SBP).
//
// API docs: https://yookassa.ru/developers/api#create_payment
func (c *Client) CreateYookassaPayment(ctx context.Context, opts YookassaCreateOpts) (*YookassaPayment, error) {
	cfg := c.cfg.Yookassa
	if !cfg.configured() {
		return nil, ErrNotConfigured
	}
	if opts.AmountRUB <= 0 {
		return nil, fmt.Errorf("yookassa: amount must be positive, got %f", opts.AmountRUB)
	}

	confirmation := map[string]string{
		"type":       "redirect",
		"return_url": opts.ReturnURL,
	}
	if opts.UseSBP {
		confirmation = map[string]string{
			"type": "qr",
		}
	}

	body := map[string]any{
		"amount": map[string]string{
			"value":    fmt.Sprintf("%.2f", opts.AmountRUB),
			"currency": "RUB",
		},
		"confirmation": confirmation,
		"capture":      true, // auto-capture, no two-step
		"description":  opts.Description,
	}
	if len(opts.Metadata) > 0 {
		body["metadata"] = opts.Metadata
	}

	// YooKassa requires SBP payment method to be specified explicitly.
	if opts.UseSBP {
		body["payment_method_data"] = map[string]string{
			"type": "sbp",
		}
	}

	var payment YookassaPayment
	if err := c.yookassaPost(ctx, "/v3/payments", body, &payment); err != nil {
		return nil, fmt.Errorf("create yookassa payment: %w", err)
	}
	if payment.ID == "" {
		return nil, fmt.Errorf("yookassa: empty payment ID in response")
	}
	return &payment, nil
}

// GetYookassaPayment fetches the current status of a YooKassa payment by ID.
//
// API docs: https://yookassa.ru/developers/api#get_payment
func (c *Client) GetYookassaPayment(ctx context.Context, paymentID string) (*YookassaPayment, error) {
	cfg := c.cfg.Yookassa
	if !cfg.configured() {
		return nil, ErrNotConfigured
	}
	if paymentID == "" {
		return nil, fmt.Errorf("yookassa: empty payment ID")
	}
	var payment YookassaPayment
	if err := c.yookassaGet(ctx, "/v3/payments/"+paymentID, &payment); err != nil {
		return nil, fmt.Errorf("get yookassa payment: %w", err)
	}
	return &payment, nil
}

// ──────────────────── HTTP plumbing ─────────────────────

func (c *Client) yookassaPost(ctx context.Context, path string, body any, out any) error {
	cfg := c.cfg.Yookassa
	url := cfg.base() + path
	buf, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.SetBasicAuth(cfg.ShopID, cfg.SecretKey)
	req.Header.Set("Content-Type", "application/json")
	// YooKassa requires Idempotence-Key for payment creation.
	req.Header.Set("Idempotence-Key", fmt.Sprintf("mosaic-%d", time.Now().UnixNano()))
	return c.doRaw(req, out)
}

func (c *Client) yookassaGet(ctx context.Context, path string, out any) error {
	cfg := c.cfg.Yookassa
	url := cfg.base() + path
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.SetBasicAuth(cfg.ShopID, cfg.SecretKey)
	req.Header.Set("Content-Type", "application/json")
	return c.doRaw(req, out)
}

// doRaw is like do() but without CryptoBot/Remnawave envelope unwrapping.
// YooKassa returns flat JSON objects.
func (c *Client) doRaw(req *http.Request, out any) error {
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return fmt.Errorf("yookassa %s: %s", resp.Status, string(body))
	}
	if out == nil || len(body) == 0 {
		return nil
	}
	return json.Unmarshal(body, out)
}
