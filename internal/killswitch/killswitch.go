package killswitch

import "net"

// KillSwitch defines the platform-agnostic interface for system network filtering.
// When enabled, it blocks all network traffic except allowed exceptions
// (tunnel interface, VPN server IP, loopback, DHCP, and allowed DNS servers).
type KillSwitch interface {
	Enable(tunnelIface string, serverIP net.IP, allowedDNS []net.IP) error
	Disable() error
	IsEnabled() bool
}

// New returns a platform-specific KillSwitch instance.
func New() KillSwitch {
	return newKillSwitch()
}
