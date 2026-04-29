// Package firewall encapsulates platform-specific OS firewall
// manipulation. On Windows it shells out to `netsh advfirewall` to
// add / remove inbound rules for the SOCKS and HTTP proxy listeners
// when the user enables ShareLAN in prefs; on Linux and macOS both
// helpers are no-ops since sing-box binding on 0.0.0.0 there is
// sufficient (no default inbound-blocking firewall).
//
// The rule name convention is "Mosaic ShareLAN <tag> <port>" so they
// can be located and deleted without tracking IDs on our side. The
// daemon calls AllowInbound when ShareLAN flips on and DenyInbound
// when it flips off (or on shutdown).
package firewall

// AllowInbound grants inbound TCP access to the given port on all
// public / private / domain profiles. Tag is a short identifier like
// "socks" or "http" used to namespace the rule. Implementation is
// provided by platform-specific files.
//
// This function never returns an error on platforms where the
// operation is a no-op.

// DenyInbound removes the rule previously added by AllowInbound with
// the same port and tag. Safe to call when no such rule exists.
