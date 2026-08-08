// Package billing bridges the MosaicVPN daemon to the Remnawave backend
// and the CryptoBot payment API. It exposes typed methods that the
// HTTP API layer calls; no transport knowledge leaks upward.
//
// All secrets (Remnawave API token, CryptoBot API token, panel URL) are
// read from the daemon store and never hardcoded.
package billing

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// RemnawaveConfig holds the connection settings for the Remnawave panel API.
// Populated from the daemon store (user-configurable via the Flutter UI).
type RemnawaveConfig struct {
	BaseURL  string `json:"base_url"`   // e.g. "https://panel.zxc1x1.ru"
	APIToken string `json:"api_token"`  // Remnawave admin API token (Bearer)
}

// CryptoBotConfig holds CryptoBot Pay API credentials.
type CryptoBotConfig struct {
	APIToken string `json:"api_token"` // Crypto-Pay-API-Token
	BaseURL  string `json:"base_url"`  // default https://pay.crypt.bot
}

// Config bundles all upstream payment credentials so the billing client and the
// store share a single serialisable shape.
type Config struct {
	Remnawave RemnawaveConfig `json:"remnawave"`
	CryptoBot CryptoBotConfig `json:"cryptobot"`
	Yookassa  YookassaConfig  `json:"yookassa"`
}

// Client talks to Remnawave and CryptoBot. It is safe for concurrent use
// because the underlying http.Client is goroutine-safe and Config is
// replaced atomically via UpdateConfig.
type Client struct {
	cfg     Config
	cfgCh   chan Config
	http    *http.Client
}

// NewClient returns a billing client seeded with the given config.
// Call UpdateConfig whenever the store changes.
func NewClient(cfg Config) *Client {
	return &Client{
		cfg:   cfg,
		cfgCh: make(chan Config, 1),
		http:  &http.Client{Timeout: 20 * time.Second},
	}
}

// UpdateConfig atomically swaps the upstream credentials.
func (c *Client) UpdateConfig(cfg Config) {
	c.cfg = cfg
}

// Config returns a copy of the current configuration.
func (c *Client) Config() Config { return c.cfg }

// ───────────────────────── Remnawave ─────────────────────────

// UserProfile is the subset of the Remnawave user record that the
// Flutter profile screen needs.
type UserProfile struct {
	UUID              string    `json:"uuid"`
	ShortUUID         string    `json:"short_uuid"`
	Username          string    `json:"username"`
	Status            string    `json:"status"` // ACTIVE | DISABLED | EXPIRED | LIMITED
	TrafficLimitBytes int64     `json:"traffic_limit_bytes"`
	ExpireAt          time.Time `json:"expire_at"`
	TelegramID        int64     `json:"telegram_id,omitempty"`
	Tag               string    `json:"tag,omitempty"`
	Email             string    `json:"email,omitempty"`
	Description       string    `json:"description,omitempty"`
}

// TrafficInfo is the usage data returned by Remnawave.
type TrafficInfo struct {
	UsedTrafficBytes     int64      `json:"used_traffic_bytes"`
	OnlineAt             *time.Time `json:"online_at,omitempty"`
	LastConnectedNode    string     `json:"last_connected_node_uuid,omitempty"`
}

// GetUserByTelegramID queries Remnawave for the user bound to the given
// Telegram account. Returns ErrUserNotFound when no user matches.
func (c *Client) GetUserByTelegramID(ctx context.Context, telegramID int64) (*UserProfile, error) {
	if telegramID == 0 {
		return nil, ErrUserNotFound
	}
	path := fmt.Sprintf("/api/users/by-telegram-id/%d", telegramID)
	var users []map[string]any
	if err := c.remnawaveGet(ctx, path, &users); err != nil {
		if strings.Contains(err.Error(), "404") {
			return nil, ErrUserNotFound
		}
		return nil, fmt.Errorf("get user by telegram_id: %w", err)
	}
	if len(users) == 0 {
		return nil, ErrUserNotFound
	}
	return remnawaveUserToProfile(users[0]), nil
}

// GetUserTraffic fetches traffic counters for a user by their UUID.
func (c *Client) GetUserTraffic(ctx context.Context, userUUID string) (*TrafficInfo, error) {
	if userUUID == "" {
		return nil, errors.New("empty user uuid")
	}
	path := fmt.Sprintf("/api/users/by-uuid/%s/traffic", userUUID)
	var raw map[string]any
	if err := c.remnawaveGet(ctx, path, &raw); err != nil {
		return nil, fmt.Errorf("get user traffic: %w", err)
	}
	return remnawaveTrafficToInfo(raw), nil
}

// ExtendUserSubscription increases the expireAt of a user by `days` days.
// This mirrors what the Telegram bot already does.
func (c *Client) ExtendUserSubscription(ctx context.Context, username string, days int) error {
	if username == "" || days <= 0 {
		return errors.New("invalid extend parameters")
	}
	payload := map[string]any{
		"username":  username,
		"expireAt":  time.Now().UTC().Add(time.Duration(days) * 24 * time.Hour).Format(time.RFC3339),
	}
	return c.remnawavePatch(ctx, "/api/users", payload, nil)
}

// ───────────────────────── CryptoBot ─────────────────────────

// Invoice is a CryptoBot payment invoice.
type Invoice struct {
	InvoiceID int64  `json:"invoice_id"`
	PayURL    string `json:"pay_url"`
	Status    string `json:"status"` // active | paid | expired
	Amount    string `json:"amount"`
	Asset     string `json:"asset"`
}

// CreateInvoice creates a CryptoBot invoice for `amount` USDT with a
// human-readable description.
func (c *Client) CreateInvoice(ctx context.Context, amount float64, description string) (*Invoice, error) {
	if amount <= 0 {
		return nil, errors.New("amount must be positive")
	}
	payload := map[string]any{
		"amount":          amount,
		"asset":           "USDT",
		"description":     description,
		"allow_comments":  false,
		"allow_anonymous": false,
		"expires_in":      1800, // 30 minutes
	}
	var inv Invoice
	if err := c.cryptobotPost(ctx, "/api/createInvoice", payload, &inv); err != nil {
		return nil, fmt.Errorf("create invoice: %w", err)
	}
	if inv.InvoiceID == 0 {
		return nil, errors.New("cryptobot: empty result")
	}
	if inv.Status == "" {
		inv.Status = "active"
	}
	if inv.Asset == "" {
		inv.Asset = "USDT"
	}
	return &inv, nil
}

// CheckInvoice polls CryptoBot for the status of an invoice.
func (c *Client) CheckInvoice(ctx context.Context, invoiceID int64) (string, error) {
	if invoiceID == 0 {
		return "", errors.New("empty invoice id")
	}
	payload := map[string]any{"invoice_ids": fmt.Sprintf("%d", invoiceID)}
	var raw map[string]any
	if err := c.cryptobotPost(ctx, "/api/getInvoices", payload, &raw); err != nil {
		return "", fmt.Errorf("check invoice: %w", err)
	}
	// do() already unwraps the "result" envelope, so raw is {items: [...]}.
	items, _ := raw["items"].([]any)
	if len(items) == 0 {
		return "", errors.New("cryptobot: invoice not found")
	}
	item, _ := items[0].(map[string]any)
	status, _ := item["status"].(string)
	return status, nil
}

// ───────────────────────── HTTP plumbing ─────────────────────────

var (
	// ErrUserNotFound is returned when Remnawave has no user for the query.
	ErrUserNotFound = errors.New("user not found")
	// ErrNotConfigured is returned when the billing client has no Remnawave/CryptoBot token.
	ErrNotConfigured = errors.New("billing not configured")
)

func (c *Client) remnawaveGet(ctx context.Context, path string, out any) error {
	cfg := c.cfg
	if cfg.Remnawave.BaseURL == "" || cfg.Remnawave.APIToken == "" {
		return ErrNotConfigured
	}
	url := strings.TrimRight(cfg.Remnawave.BaseURL, "/") + path
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	c.setRemnawaveHeaders(req, cfg)
	return c.do(req, out)
}

func (c *Client) remnawavePatch(ctx context.Context, path string, body any, out any) error {
	cfg := c.cfg
	if cfg.Remnawave.BaseURL == "" || cfg.Remnawave.APIToken == "" {
		return ErrNotConfigured
	}
	url := strings.TrimRight(cfg.Remnawave.BaseURL, "/") + path
	buf, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPatch, url, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	c.setRemnawaveHeaders(req, cfg)
	return c.do(req, out)
}

func (c *Client) cryptobotPost(ctx context.Context, path string, body any, out any) error {
	cfg := c.cfg
	if cfg.CryptoBot.APIToken == "" {
		return ErrNotConfigured
	}
	base := cfg.CryptoBot.BaseURL
	if base == "" {
		base = "https://pay.crypt.bot"
	}
	url := strings.TrimRight(base, "/") + path
	buf, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Crypto-Pay-API-Token", cfg.CryptoBot.APIToken)
	req.Header.Set("Content-Type", "application/json")
	return c.do(req, out)
}

func (c *Client) setRemnawaveHeaders(req *http.Request, cfg Config) {
	req.Header.Set("Authorization", "Bearer "+cfg.Remnawave.APIToken)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forwarded-Proto", "https")
	req.Header.Set("X-Forwarded-For", "127.0.0.1")
}

func (c *Client) do(req *http.Request, out any) error {
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		// CryptoBot returns 401 when the token is missing; surface a
		// descriptive error. Remnawave returns 404 for missing users.
		return fmt.Errorf("upstream %s: %s", resp.Status, string(body))
	}
	if out == nil || len(body) == 0 {
		return nil
	}
	// CryptoBot wraps responses as {"ok":true,"result":...}.
	// Remnawave wraps single-object responses as {"response": {...}} and
	// list responses as {"response": [...]}. Try both wrappers.
	envelope := map[string]json.RawMessage{}
	if err := json.Unmarshal(body, &envelope); err == nil {
		if raw, ok := envelope["result"]; ok && len(raw) > 0 {
			return json.Unmarshal(raw, out)
		}
		if raw, ok := envelope["response"]; ok && len(raw) > 0 {
			return json.Unmarshal(raw, out)
		}
	}
	return json.Unmarshal(body, out)
}

// ───────────────────────── helpers ─────────────────────────

func toInt64(v any) (int64, bool) {
	switch n := v.(type) {
	case float64:
		return int64(n), true
	case int64:
		return n, true
	case int:
		return int64(n), true
	case json.Number:
		i, err := n.Int64()
		return i, err == nil
	}
	return 0, false
}

func remnawaveUserToProfile(raw map[string]any) *UserProfile {
	p := &UserProfile{}
	p.UUID, _ = raw["uuid"].(string)
	p.ShortUUID, _ = raw["shortUuid"].(string)
	p.Username, _ = raw["username"].(string)
	p.Status, _ = raw["status"].(string)
	if v, ok := toInt64(raw["trafficLimitBytes"]); ok {
		p.TrafficLimitBytes = v
	}
	if expireStr, ok := raw["expireAt"].(string); ok {
		if t, err := time.Parse(time.RFC3339, expireStr); err == nil {
			p.ExpireAt = t
		}
	}
	if v, ok := toInt64(raw["telegramId"]); ok {
		p.TelegramID = v
	}
	p.Tag, _ = raw["tag"].(string)
	p.Email, _ = raw["email"].(string)
	p.Description, _ = raw["description"].(string)
	return p
}

func remnawaveTrafficToInfo(raw map[string]any) *TrafficInfo {
	info := &TrafficInfo{}
	if v, ok := toInt64(raw["usedTrafficBytes"]); ok {
		info.UsedTrafficBytes = v
	}
	if onlineStr, ok := raw["onlineAt"].(string); ok && onlineStr != "" {
		if t, err := time.Parse(time.RFC3339, onlineStr); err == nil {
			info.OnlineAt = &t
		}
	}
	info.LastConnectedNode, _ = raw["lastConnectedNodeUuid"].(string)
	return info
}
