package store

import (
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"strings"
	"time"
)

// Account linking and payment history.
//
// T-19 requires the client to link to a Mosaic account using a short code
// issued by @mosaicvpnbot rather than a raw telegram_id. A raw ID is a
// public identifier: anyone who knows a victim's Telegram ID could bind a
// client to that account and read its tariff and traffic. A code proves the
// person holding the client also controls the Telegram account, because only
// the bot chat shows it.
//
// The code is therefore a bearer credential with the usual obligations:
// single use, short TTL, constant-time comparison, and a redemption attempt
// limit so it cannot be brute-forced.

// LinkCodeLength is the number of characters in a pairing code.
//
// Codes are read off a phone screen and typed by hand, so they stay short.
// 8 characters over a 32-symbol alphabet is 40 bits of entropy, which with a
// 10-minute TTH and a 5-attempt cap leaves a negligible guessing chance while
// staying comfortable to type.
const LinkCodeLength = 8

// linkCodeAlphabet excludes visually ambiguous characters (0/O, 1/I/L) so a
// user reading a code off a phone screen does not mistype it.
const linkCodeAlphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"

// DefaultLinkCodeTTL is how long an issued pairing code stays valid.
const DefaultLinkCodeTTL = 10 * time.Minute

// MaxLinkCodeAttempts is the number of failed redemptions tolerated before a
// code is burned. Without a cap, a 40-bit code could be ground down by an
// attacker with local API access.
const MaxLinkCodeAttempts = 5

var (
	// ErrLinkCodeNotFound is returned when no code matches the input.
	ErrLinkCodeNotFound = errors.New("link code not found")
	// ErrLinkCodeExpired is returned when a code exists but its TTL passed.
	ErrLinkCodeExpired = errors.New("link code expired")
	// ErrLinkCodeUsed is returned when a code was already redeemed.
	ErrLinkCodeUsed = errors.New("link code already used")
	// ErrLinkCodeAttempts is returned when a code was burned by too many
	// failed redemption attempts.
	ErrLinkCodeAttempts = errors.New("link code blocked: too many attempts")
)

// LinkCode is a single-use pairing code issued by the bot.
type LinkCode struct {
	// Code is the normalized (upper-case) pairing code.
	Code string `json:"code"`
	// TelegramID is the account the code links to.
	TelegramID int64 `json:"telegram_id"`
	// Username is cached for display right after linking, before the first
	// Remnawave profile fetch completes.
	Username string `json:"username,omitempty"`
	// SessionToken is the opaque token handed to the daemon on redemption.
	SessionToken string `json:"session_token,omitempty"`
	// IssuedAt and ExpiresAt bound the validity window.
	IssuedAt  time.Time `json:"issued_at"`
	ExpiresAt time.Time `json:"expires_at"`
	// UsedAt is set on successful redemption; a non-zero value means the
	// code is spent.
	UsedAt time.Time `json:"used_at,omitempty"`
	// Attempts counts failed redemption attempts against this code.
	Attempts int `json:"attempts,omitempty"`
}

// Expired reports whether the code is past its TTL at time now.
func (c LinkCode) Expired(now time.Time) bool {
	return !c.ExpiresAt.IsZero() && now.After(c.ExpiresAt)
}

// Used reports whether the code was already redeemed.
func (c LinkCode) Used() bool { return !c.UsedAt.IsZero() }

// Blocked reports whether the code was burned by failed attempts.
func (c LinkCode) Blocked() bool { return c.Attempts >= MaxLinkCodeAttempts }

// PaymentEntry is one row of the account payment history shown in the
// cabinet. It is written by the top-up flows (CryptoBot, YooKassa, lava)
// so the user can reconcile what they paid against what they got.
type PaymentEntry struct {
	// ID is the provider-side payment or invoice identifier.
	ID string `json:"id"`
	// Provider is the payment driver: "cryptobot" | "yookassa" | "lava".
	Provider string `json:"provider"`
	// Amount is the charged amount in Currency units.
	Amount float64 `json:"amount"`
	// Currency is an ISO-4217-ish code ("RUB", "USDT").
	Currency string `json:"currency"`
	// Status is the lifecycle state: "pending" | "paid" | "failed" |
	// "canceled".
	Status string `json:"status"`
	// Days is the subscription days granted by this payment, when known.
	Days int `json:"days,omitempty"`
	// Description is a human-readable note.
	Description string `json:"description,omitempty"`
	// CreatedAt is when the payment was initiated, PaidAt when it settled.
	CreatedAt time.Time `json:"created_at"`
	PaidAt    time.Time `json:"paid_at,omitempty"`
}

// maxPaymentHistory caps stored history. The cabinet shows recent activity,
// and the store is a JSON file rewritten on every update — unbounded growth
// would make each write progressively more expensive.
const maxPaymentHistory = 200

// NewLinkCode generates a cryptographically random pairing code.
//
// crypto/rand is used rather than math/rand: a predictable code is
// equivalent to no code at all.
func NewLinkCode() (string, error) {
	buf := make([]byte, LinkCodeLength)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	out := make([]byte, LinkCodeLength)
	// Rejection-free mapping is not needed here: the alphabet length (31) is
	// close enough to 256/8 that modulo bias is immaterial for a short-lived
	// single-use code, and uniformity is preserved well within the guessing
	// budget the attempt cap allows.
	for i, b := range buf {
		out[i] = linkCodeAlphabet[int(b)%len(linkCodeAlphabet)]
	}
	return string(out), nil
}

// NormalizeLinkCode canonicalizes user input: upper-cased, stripped of
// spaces and dashes people naturally insert when reading a code aloud.
func NormalizeLinkCode(code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	code = strings.ReplaceAll(code, "-", "")
	code = strings.ReplaceAll(code, " ", "")
	return code
}

// IssueLinkCode stores a new pairing code for telegramID.
//
// Any unused code previously issued to the same account is dropped, so a
// user who taps "get code" twice cannot leave a valid code dangling in an
// old bot message.
func (s *Store) IssueLinkCode(telegramID int64, username, sessionToken string, ttl time.Duration) (LinkCode, error) {
	if telegramID == 0 {
		return LinkCode{}, errors.New("telegram_id required")
	}
	if ttl <= 0 {
		ttl = DefaultLinkCodeTTL
	}
	raw, err := NewLinkCode()
	if err != nil {
		return LinkCode{}, err
	}
	now := time.Now().UTC()
	entry := LinkCode{
		Code:         raw,
		TelegramID:   telegramID,
		Username:     username,
		SessionToken: sessionToken,
		IssuedAt:     now,
		ExpiresAt:    now.Add(ttl),
	}
	err = s.Update(func(st *State) error {
		kept := st.LinkCodes[:0]
		for _, c := range st.LinkCodes {
			// Drop this account's still-live codes and anything already
			// spent or expired: keeping them serves no purpose and grows
			// the state file.
			if c.TelegramID == telegramID && !c.Used() {
				continue
			}
			if c.Used() || c.Expired(now) {
				continue
			}
			kept = append(kept, c)
		}
		st.LinkCodes = append(kept, entry)
		return nil
	})
	if err != nil {
		return LinkCode{}, err
	}
	return entry, nil
}

// RedeemLinkCode validates a pairing code and, on success, links the account.
//
// Returns the redeemed code on success. Failures increment the attempt
// counter for an existing code so brute force is bounded.
func (s *Store) RedeemLinkCode(input string) (LinkCode, error) {
	norm := NormalizeLinkCode(input)
	if norm == "" {
		return LinkCode{}, ErrLinkCodeNotFound
	}
	var out LinkCode
	err := s.Update(func(st *State) error {
		now := time.Now().UTC()
		idx := -1
		for i := range st.LinkCodes {
			// Constant-time compare: a timing side channel would leak the
			// code prefix byte by byte and defeat the attempt cap.
			if subtle.ConstantTimeCompare([]byte(st.LinkCodes[i].Code), []byte(norm)) == 1 {
				idx = i
				break
			}
		}
		if idx < 0 {
			return ErrLinkCodeNotFound
		}
		c := st.LinkCodes[idx]
		switch {
		case c.Blocked():
			return ErrLinkCodeAttempts
		case c.Used():
			// Count a replay as an attempt so a leaked spent code cannot be
			// used to probe indefinitely.
			st.LinkCodes[idx].Attempts++
			return ErrLinkCodeUsed
		case c.Expired(now):
			st.LinkCodes[idx].Attempts++
			return ErrLinkCodeExpired
		}
		st.LinkCodes[idx].UsedAt = now
		out = st.LinkCodes[idx]
		// Link the account in the same atomic update as burning the code:
		// a crash between the two would otherwise either spend a code
		// without linking or link without spending.
		st.Account = Account{
			TelegramID:   c.TelegramID,
			SessionToken: c.SessionToken,
			Username:     c.Username,
			ExpireAt:     st.Account.ExpireAt,
		}
		return nil
	})
	if err != nil {
		return LinkCode{}, err
	}
	return out, nil
}

// GetLinkCode returns a stored code by value, or nil. Intended for tests and
// diagnostics rather than the redemption path.
func (s *Store) GetLinkCode(code string) *LinkCode {
	norm := NormalizeLinkCode(code)
	s.mu.RLock()
	defer s.mu.RUnlock()
	for i := range s.state.LinkCodes {
		if s.state.LinkCodes[i].Code == norm {
			c := s.state.LinkCodes[i] // copy
			return &c
		}
	}
	return nil
}

// PruneLinkCodes drops spent and expired codes. Safe to call periodically.
func (s *Store) PruneLinkCodes() error {
	return s.Update(func(st *State) error {
		now := time.Now().UTC()
		kept := make([]LinkCode, 0, len(st.LinkCodes))
		for _, c := range st.LinkCodes {
			if c.Used() || c.Expired(now) {
				continue
			}
			kept = append(kept, c)
		}
		st.LinkCodes = kept
		return nil
	})
}

// ────────── Payment history ─────────────────────────────────────────

// AddPayment appends or updates a payment history row, keyed by
// provider+ID so a status transition (pending → paid) updates in place
// instead of duplicating the row.
func (s *Store) AddPayment(p PaymentEntry) error {
	if p.ID == "" {
		return errors.New("payment id required")
	}
	if p.CreatedAt.IsZero() {
		p.CreatedAt = time.Now().UTC()
	}
	return s.Update(func(st *State) error {
		for i := range st.Payments {
			if st.Payments[i].ID == p.ID && st.Payments[i].Provider == p.Provider {
				// Preserve the original CreatedAt: a status update must not
				// rewrite when the payment was started.
				created := st.Payments[i].CreatedAt
				st.Payments[i] = p
				st.Payments[i].CreatedAt = created
				return nil
			}
		}
		st.Payments = append(st.Payments, p)
		if len(st.Payments) > maxPaymentHistory {
			st.Payments = st.Payments[len(st.Payments)-maxPaymentHistory:]
		}
		return nil
	})
}

// ListPayments returns payment history, newest first.
func (s *Store) ListPayments() []PaymentEntry {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := append([]PaymentEntry(nil), s.state.Payments...)
	// Newest first: the cabinet shows recent activity at the top.
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}
