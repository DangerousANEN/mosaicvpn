package killswitch

import (
	"net"
	"sync"
	"testing"
)

func TestKillSwitchInterface(t *testing.T) {
	ks := New()
	if ks == nil {
		t.Fatal("New() returned nil")
	}

	if ks.IsEnabled() {
		t.Errorf("expected IsEnabled() to be false initially")
	}
}

func TestKillSwitchStateTransitions(t *testing.T) {
	ks := New()

	// Disable when already disabled should not fail
	if err := ks.Disable(); err != nil {
		t.Errorf("Disable() returned error when disabled: %v", err)
	}

	if ks.IsEnabled() {
		t.Errorf("expected IsEnabled() to be false")
	}
}

func TestKillSwitchEnableDisable(t *testing.T) {
	ks := New()

	serverIP := net.ParseIP("192.168.1.100")
	dns1 := net.ParseIP("1.1.1.1")
	dns2 := net.ParseIP("8.8.8.8")
	allowedDNS := []net.IP{dns1, dns2}

	// Try enabling killswitch
	err := ks.Enable("", serverIP, allowedDNS)
	if err == nil {
		if !ks.IsEnabled() {
			t.Errorf("expected IsEnabled() to be true after successful Enable()")
		}
		if err := ks.Disable(); err != nil {
			t.Errorf("Disable() returned error: %v", err)
		}
		if ks.IsEnabled() {
			t.Errorf("expected IsEnabled() to be false after Disable()")
		}
	} else {
		// When running non-elevated on Windows, access denied is expected
		t.Logf("Enable returned (expected if non-admin): %v", err)
		if ks.IsEnabled() {
			t.Errorf("expected IsEnabled() to be false after failed Enable()")
		}
	}
}

func TestKillSwitchConcurrentAccess(t *testing.T) {
	ks := New()

	serverIP := net.ParseIP("10.0.0.1")
	dnsIP := net.ParseIP("9.9.9.9")

	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(3)
		go func() {
			defer wg.Done()
			_ = ks.IsEnabled()
		}()
		go func() {
			defer wg.Done()
			_ = ks.Enable("", serverIP, []net.IP{dnsIP})
		}()
		go func() {
			defer wg.Done()
			_ = ks.Disable()
		}()
	}
	wg.Wait()

	_ = ks.Disable()
	if ks.IsEnabled() {
		t.Errorf("expected IsEnabled() to be false after cleanup")
	}
}
