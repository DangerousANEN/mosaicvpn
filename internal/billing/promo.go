package billing

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"strings"
	"time"
)

// Promo represents a promotional code that grants subscription days
// or balance credit when redeemed.
type Promo struct {
	Code       string    `json:"code"`        // unique promo code (uppercased)
	Type       string    `json:"type"`        // "days" | "balance"
	Value      int       `json:"value"`       // days to add (type=days) or rubles to credit (type=balance)
	MaxUses    int       `json:"max_uses"`    // 0 = unlimited
	UsedCount  int       `json:"used_count"`  // how many times redeemed
	ExpiresAt  time.Time `json:"expires_at"`  // zero = never expires
	CreatedAt  time.Time `json:"created_at"`
	CreatedBy  string    `json:"created_by"`  // admin username who created it
	Active     bool      `json:"active"`      // can be deactivated manually
}

// PromoRedemption records who redeemed which promo and when.
type PromoRedemption struct {
	Code       string    `json:"code"`
	Username   string    `json:"username"`    // Remnawave username
	TelegramID int64     `json:"telegram_id"`
	RedeemedAt time.Time `json:"redeemed_at"`
	GrantedValue int     `json:"granted_value"` // what they got
	GrantedType  string  `json:"granted_type"`  // "days" | "balance"
}

// PromoErrors
var (
	ErrPromoNotFound   = errors.New("promo code not found")
	ErrPromoExpired    = errors.New("promo code has expired")
	ErrPromoInactive   = errors.New("promo code is inactive")
	ErrPromoMaxUses    = errors.New("promo code usage limit reached")
	ErrPromoAlreadyUsed = errors.New("promo code already used by this user")
)

// ValidatePromo checks if a promo code is valid for redemption.
// Does NOT check per-user uniqueness — that's the caller's job.
func ValidatePromo(promo *Promo) error {
	if promo == nil {
		return ErrPromoNotFound
	}
	if !promo.Active {
		return ErrPromoInactive
	}
	if !promo.ExpiresAt.IsZero() && time.Now().UTC().After(promo.ExpiresAt) {
		return ErrPromoExpired
	}
	if promo.MaxUses > 0 && promo.UsedCount >= promo.MaxUses {
		return ErrPromoMaxUses
	}
	return nil
}

// NormalizePromoCode uppercases and trims a promo code for consistent lookup.
func NormalizePromoCode(code string) string {
	return strings.ToUpper(strings.TrimSpace(code))
}

// GeneratePromoCode creates a random promo code like "MOSAIC-A1B2C3".
func GeneratePromoCode() string {
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	return "MOSAIC-" + strings.ToUpper(hex.EncodeToString(b))
}
