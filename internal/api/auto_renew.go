package api

import (
	"context"
	"fmt"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/logx"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

// StartAutoRenew runs a background loop that checks subscription expiry
// and logs notifications at 3 days, 1 day, and on expiry.
//
// Auto-renewal from balance is a TODO — requires YooKassa balance tracking.
// For now this loop only monitors and logs expiry warnings.
//
// Started from main.go alongside StartAutoUpdate.
func (s *Server) StartAutoRenew(ctx context.Context) {
	const checkInterval = 1 * time.Hour

	logx.Info("auto-renew loop started", "interval", checkInterval)

	// Initial check after a short delay (let other services start)
	time.Sleep(10 * time.Second)
	s.checkExpiry(ctx)

	ticker := time.NewTicker(checkInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			logx.Info("auto-renew loop stopped")
			return
		case <-ticker.C:
			s.checkExpiry(ctx)
		}
	}
}

// checkExpiry fetches the linked account's subscription expiry from
// Remnawave and logs warnings when it's about to expire.
func (s *Server) checkExpiry(ctx context.Context) {
	account := s.store.GetAccount()
	if account.Username == "" || account.TelegramID == 0 {
		return // no linked account
	}

	// Fetch fresh profile from Remnawave
	profile, err := s.billing.GetUserByTelegramID(ctx, account.TelegramID)
	if err != nil {
		logx.Warn("auto-renew: failed to fetch user profile", "err", err)
		return
	}

	expireAt := profile.ExpireAt
	daysLeft := int(time.Until(expireAt).Hours() / 24)

	// Update cached expiry in store if it changed
	if !expireAt.IsZero() && !expireAt.Equal(account.ExpireAt) {
		updated := account
		updated.ExpireAt = expireAt
		if err := s.store.SetAccount(store.Account(updated)); err != nil {
			logx.Warn("auto-renew: failed to update cached expiry", "err", err)
		}
	}

	// Log expiry status
	switch {
	case daysLeft <= 0:
		logx.Warn("subscription expired",
			"user", profile.Username,
			"expired_at", expireAt.Format(time.RFC3339),
		)
	case daysLeft <= 3:
		logx.Info(fmt.Sprintf("subscription expiring in %d day(s)", daysLeft),
			"user", profile.Username,
			"expire_at", expireAt.Format(time.RFC3339),
		)
	default:
		logx.Info("subscription ok",
			"user", profile.Username,
			"days_left", daysLeft,
		)
	}
}
