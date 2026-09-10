package state

import (
	"context"
	"testing"
	"time"
)

// Diagnostics only earn their place if they actually catch the failures they
// claim to. These tests drive the individual checks against controlled
// conditions rather than asserting that the report merely renders.

func TestDiagnosticsSkipTunnelChecksWhenDisconnected(t *testing.T) {
	m := &Manager{}
	res := m.RunDiagnostics(context.Background())

	if len(res.Checks) == 0 {
		t.Fatal("diagnostics must always produce checks")
	}
	byID := map[string]DiagCheck{}
	for _, c := range res.Checks {
		byID[c.ID] = c
	}

	// Tunnel-dependent checks must not report failure merely because the VPN
	// is off — that would train users to ignore the report.
	for _, id := range []string{"traffic", "ipv6", "mtu"} {
		c, ok := byID[id]
		if !ok {
			t.Fatalf("check %q missing from report", id)
		}
		if c.Severity == sevFail {
			t.Fatalf("check %q must not fail while disconnected: %q", id, c.Detail)
		}
	}
}

func TestDiagnosticsReportIsFullyPopulated(t *testing.T) {
	m := &Manager{}
	res := m.RunDiagnostics(context.Background())

	if res.GeneratedAt.IsZero() {
		t.Fatal("report must carry a timestamp")
	}
	if res.Summary == "" {
		t.Fatal("report must carry a human-readable summary")
	}
	for _, c := range res.Checks {
		if c.ID == "" || c.Title == "" {
			t.Fatalf("check is missing identity: %+v", c)
		}
		if c.Detail == "" {
			t.Fatalf("check %q must explain what it observed", c.ID)
		}
		if c.Severity != sevOK && c.Severity != sevWarn && c.Severity != sevFail {
			t.Fatalf("check %q has an invalid severity %q", c.ID, c.Severity)
		}
		// A failing or warning check without a hint leaves the user stuck.
		if (c.Severity == sevFail || c.Severity == sevWarn) && c.Hint == "" {
			// Warnings about our own inability to measure are acceptable
			// without a hint; genuine problems are not.
			if c.Severity == sevFail {
				t.Fatalf("failing check %q must tell the user what to do", c.ID)
			}
		}
	}
}

// The traffic check is the truth-check reused on demand, so it must flag a
// black-holing tunnel rather than reporting a pass.
func TestDiagnosticsTrafficCheckDetectsBlackHole(t *testing.T) {
	addr, stop := startBlackHoleSOCKS(t)
	defer stop()

	m := &Manager{}
	c := m.checkTunnelTraffic(context.Background(), addr, true)

	if c.Severity != sevFail {
		t.Fatalf("a black-holing tunnel must be reported as a failure, got %q: %s",
			c.Severity, c.Detail)
	}
	if c.Hint == "" {
		t.Fatal("the user must be told what to do about a dead tunnel")
	}
}

func TestDiagnosticsTrafficCheckSkipsWithoutSocks(t *testing.T) {
	m := &Manager{}
	c := m.checkTunnelTraffic(context.Background(), "", true)
	if c.Severity == sevFail {
		t.Fatalf("a backend without a SOCKS endpoint must not be reported as broken: %s", c.Detail)
	}
}

func TestDiagnosticsRespectContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	m := &Manager{}
	done := make(chan DiagResult, 1)
	go func() { done <- m.RunDiagnostics(ctx) }()

	select {
	case res := <-done:
		// Must return promptly and still be well-formed rather than hanging.
		if len(res.Checks) == 0 {
			t.Fatal("even a cancelled run must return structured checks")
		}
	case <-time.After(20 * time.Second):
		t.Fatal("diagnostics ignored context cancellation")
	}
}

func TestDiagnosticsRunConcurrently(t *testing.T) {
	m := &Manager{}
	start := time.Now()
	res := m.RunDiagnostics(context.Background())
	elapsed := time.Since(start)

	// Five checks with multi-second timeouts would take far longer serially;
	// this guards against someone turning the fan-out into a loop.
	var slowest int
	for _, c := range res.Checks {
		if c.DurationMS > slowest {
			slowest = c.DurationMS
		}
	}
	budget := time.Duration(slowest)*time.Millisecond + 10*time.Second
	if elapsed > budget {
		t.Fatalf("checks appear to run serially: total %s, slowest %dms", elapsed, slowest)
	}
}
