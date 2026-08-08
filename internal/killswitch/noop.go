//go:build !windows

package killswitch

import (
	"net"
	"sync"
)

type noopKillSwitch struct {
	mu      sync.Mutex
	enabled bool
}

func newKillSwitch() KillSwitch {
	return &noopKillSwitch{}
}

func (n *noopKillSwitch) Enable(tunnelIface string, serverIP net.IP, allowedDNS []net.IP) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.enabled = true
	return nil
}

func (n *noopKillSwitch) Disable() error {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.enabled = false
	return nil
}

func (n *noopKillSwitch) IsEnabled() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.enabled
}
