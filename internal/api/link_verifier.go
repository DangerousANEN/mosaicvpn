package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	urlpkg "net/url"
	"strings"
	"time"
)

// Remote pairing-code verification.
//
// Topology matters here: the bot runs on the provider's VPS while the daemon
// runs on the user's machine, usually behind NAT. The bot therefore cannot
// push a code into the daemon — it can only show the code in the Telegram
// chat. The daemon is the side that can make outbound calls, so the daemon
// verifies the typed code against the bot.
//
// The local store path stays as a fallback for self-hosted setups where the
// same operator runs both sides and no bot endpoint is configured.

// ErrVerifierUnavailable means the bot could not be reached at all, as
// opposed to the bot rejecting the code. The two must not be conflated: a
// network blip should not tell the user their code is wrong.
var ErrVerifierUnavailable = errors.New("link verifier unavailable")

// ErrLinkCodeMalformed is returned before a remote request when the user
// supplied fewer than eight symbols from the unambiguous Mosaic pairing
// alphabet. This prevents an avoidable production HTTP 400 and lets every
// client present the same actionable message.
var ErrLinkCodeMalformed = errors.New("invalid pairing code format")

const pairingCodeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

func normalizePairingCode(raw string) string {
	var normalized strings.Builder
	normalized.Grow(8)
	for _, r := range strings.ToUpper(raw) {
		if strings.ContainsRune(pairingCodeAlphabet, r) {
			normalized.WriteRune(r)
		}
	}
	return normalized.String()
}

// LinkVerification is what the bot returns for a valid code.
type LinkVerification struct {
	TelegramID    int64  `json:"telegram_id"`
	Username      string `json:"username"`
	SessionToken  string `json:"session_token"`
	DirectToken   string `json:"direct_token"`
	DirectFeedURL string `json:"-"`
}

// LinkVerifier redeems a pairing code against a remote authority.
type LinkVerifier interface {
	Verify(ctx context.Context, code string) (LinkVerification, error)
}

// EmailLogin is the minimal response needed by a daemon after a password
// login. The client token is scoped only to direct feed access.
type EmailLogin struct {
	AccountID string `json:"account_id"`
	// SessionToken is the web-scoped unified account session. It is kept only
	// in the local daemon store and is never exposed to Flutter widgets.
	SessionToken  string `json:"token"`
	ClientToken   string `json:"client_token"`
	Email         string `json:"-"`
	DirectFeedURL string `json:"-"`
}

// EmailAuthenticator authenticates a password at the provider authority.
type EmailAuthenticator interface {
	Login(ctx context.Context, email, password string) (EmailLogin, error)
}

// BotLinkVerifier calls the bot's HTTP API.
type BotLinkVerifier struct {
	// BaseURL is the bot's public API root, e.g. https://mosaicvpn.app/bot.
	BaseURL string
	// Client is optional; a sane default with a timeout is used when nil.
	Client *http.Client
}

// NewBotLinkVerifier builds a verifier with a bounded timeout.
//
// A timeout is mandatory: without one, a hung VPS would freeze the link
// request until the user gave up, with the UI stuck on a spinner.
func NewBotLinkVerifier(baseURL string) *BotLinkVerifier {
	return &BotLinkVerifier{
		BaseURL: baseURL,
		Client:  &http.Client{Timeout: 10 * time.Second},
	}
}

// Verify redeems code against the bot.
//
// Status mapping mirrors the daemon's own API so the Flutter client sees one
// consistent contract regardless of which side actually burned the code.
func (v *BotLinkVerifier) Verify(ctx context.Context, code string) (LinkVerification, error) {
	code = normalizePairingCode(code)
	if len(code) != 8 {
		return LinkVerification{}, ErrLinkCodeMalformed
	}
	if v.BaseURL == "" {
		return LinkVerification{}, ErrVerifierUnavailable
	}
	client := v.Client
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}

	body, err := json.Marshal(map[string]string{"code": code})
	if err != nil {
		return LinkVerification{}, err
	}
	url := v.BaseURL + "/api/link/redeem"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return LinkVerification{}, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		// Transport failure is not a verdict on the code.
		return LinkVerification{}, fmt.Errorf("%w: %v", ErrVerifierUnavailable, err)
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusOK:
		var out LinkVerification
		raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
		if err != nil {
			return LinkVerification{}, fmt.Errorf("%w: %v", ErrVerifierUnavailable, err)
		}
		if err := json.Unmarshal(raw, &out); err != nil {
			return LinkVerification{}, fmt.Errorf("%w: bad response", ErrVerifierUnavailable)
		}
		if out.TelegramID == 0 {
			return LinkVerification{}, fmt.Errorf("%w: empty telegram_id", ErrVerifierUnavailable)
		}
		// DirectToken is optional for compatibility with self-hosted/old bot
		// deployments. When present, it creates a per-device direct feed URL.
		if out.DirectToken != "" {
			base := strings.TrimRight(v.BaseURL, "/")
			out.DirectFeedURL = base + "/api/direct/singbox?token=" + urlpkg.QueryEscape(out.DirectToken)
		}
		return out, nil
	case http.StatusNotFound:
		return LinkVerification{}, errLinkNotFound
	case http.StatusGone:
		return LinkVerification{}, errLinkExpired
	case http.StatusConflict:
		return LinkVerification{}, errLinkUsed
	case http.StatusTooManyRequests:
		return LinkVerification{}, errLinkAttempts
	default:
		// 5xx from the bot is an outage, not a bad code.
		return LinkVerification{}, fmt.Errorf("%w: status %d", ErrVerifierUnavailable, resp.StatusCode)
	}
}

// Sentinel errors mirroring the store's, so the handler can map either source
// onto the same HTTP status without importing store semantics twice.
var (
	errLinkNotFound = errors.New("code not found")
	errLinkExpired  = errors.New("code expired")
	errLinkUsed     = errors.New("code already used")
	errLinkAttempts = errors.New("too many attempts")
)

// Login authenticates a non-Telegram account and returns a client-scoped
// credential. Passwords are sent only over HTTPS to the provider and never
// written to the daemon store.
func (v *BotLinkVerifier) Login(ctx context.Context, email, password string) (EmailLogin, error) {
	if v.BaseURL == "" {
		return EmailLogin{}, ErrVerifierUnavailable
	}
	body, err := json.Marshal(map[string]string{"email": email, "password": password})
	if err != nil {
		return EmailLogin{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(v.BaseURL, "/")+"/api/auth/login", bytes.NewReader(body))
	if err != nil {
		return EmailLogin{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := v.Client
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return EmailLogin{}, fmt.Errorf("%w: %v", ErrVerifierUnavailable, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized {
		return EmailLogin{}, errors.New("invalid email or password")
	}
	if resp.StatusCode != http.StatusOK {
		return EmailLogin{}, fmt.Errorf("%w: status %d", ErrVerifierUnavailable, resp.StatusCode)
	}
	var out EmailLogin
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil || json.Unmarshal(raw, &out) != nil || out.ClientToken == "" {
		return EmailLogin{}, fmt.Errorf("%w: bad response", ErrVerifierUnavailable)
	}
	out.Email = strings.TrimSpace(strings.ToLower(email))
	out.DirectFeedURL = strings.TrimRight(v.BaseURL, "/") + "/api/direct/singbox?token=" + urlpkg.QueryEscape(out.ClientToken)
	return out, nil
}
