package state

import (
	"context"
	"errors"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

// ErrRuntimeUnavailable is surfaced when MosaicVPN was installed without a
// usable sing-box runtime. It must be treated as an installation/runtime
// problem, never as a connected mock session.
var ErrRuntimeUnavailable = errors.New("VPN runtime unavailable: sing-box was not found next to mosaicd or on PATH")

// UnavailableBackend keeps the daemon API available for account recovery and
// diagnostics while truthfully rejecting connection attempts. Production
// builds use this instead of MockBackend whenever the embedded runtime cannot
// be located.
type UnavailableBackend struct {
	reason error
}

func NewUnavailableBackend(reason error) *UnavailableBackend {
	if reason == nil {
		reason = ErrRuntimeUnavailable
	}
	return &UnavailableBackend{reason: reason}
}

func (b *UnavailableBackend) Name() string { return "unavailable" }

func (b *UnavailableBackend) Start(context.Context, proto.Server, store.Prefs, []proto.Rule) error {
	return b.reason
}

func (b *UnavailableBackend) Stop(context.Context) error { return nil }

func (b *UnavailableBackend) Stats() (uint64, uint64, int) { return 0, 0, 0 }
