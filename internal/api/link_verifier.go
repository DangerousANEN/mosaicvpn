package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
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

// LinkVerification is what the bot returns for a valid code.
type LinkVerification struct {
	TelegramID   int64  `json:"telegram_id"`
	Username     string `json:"username"`
	SessionToken string `json:"session_token"`
}

// LinkVerifier redeems a pairing code against a remote authority.
type LinkVerifier interface {
	Verify(ctx context.Context, code string) (LinkVerification, error)
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
