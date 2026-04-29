//go:build !windows

package firewall

// AllowInbound is a no-op on non-Windows platforms. sing-box binding
// on 0.0.0.0 is sufficient there — Linux and macOS don't ship a
// default-deny inbound firewall for user-space TCP listeners.
func AllowInbound(tag string, port int) error { return nil }

// DenyInbound is a no-op on non-Windows platforms.
func DenyInbound(tag string, port int) error { return nil }
