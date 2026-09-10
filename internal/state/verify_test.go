package state

import (
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// These tests pin the behaviour that shipped incidents demanded: a core that
// starts cleanly but moves no traffic must NOT be reported as connected.
//
// The black-hole SOCKS server below reproduces the real sing-box-multiplex
// failure: the proxy completes the SOCKS5 handshake (so a naive TCP-level
// check passes), then never carries any payload. That is precisely the shape
// of failure that made the UI show a green shield over a dead tunnel.

// startBlackHoleSOCKS accepts SOCKS5 connections, completes the handshake and
// then swallows everything, never returning data.
func startBlackHoleSOCKS(t *testing.T) (addr string, stop func()) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	var wg sync.WaitGroup
	done := make(chan struct{})

	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			wg.Add(1)
			go func(c net.Conn) {
				defer wg.Done()
				defer c.Close()
				buf := make([]byte, 512)
				// greeting: VER NMETHODS METHODS...
				if _, err := c.Read(buf); err != nil {
					return
				}
				// select "no auth"
				if _, err := c.Write([]byte{0x05, 0x00}); err != nil {
					return
				}
				// connect request
				if _, err := c.Read(buf); err != nil {
					return
				}
				// success reply, bound to 0.0.0.0:0
				if _, err := c.Write([]byte{
					0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0,
				}); err != nil {
					return
				}
				// ...and now behave like the real failure: accept the request
				// bytes and never answer. Hold until the test tears down.
				go func() { _, _ = io.Copy(io.Discard, c) }()
				<-done
			}(conn)
		}
	}()

	return ln.Addr().String(), func() {
		close(done)
		_ = ln.Close()
		wg.Wait()
	}
}

func TestVerifyTunnelDetectsBlackHole(t *testing.T) {
	addr, stop := startBlackHoleSOCKS(t)
	defer stop()

	// Keep the probe short: we are asserting detection, not patience.
	policy := VerifyPolicy{
		Attempts:          2,
		PerAttemptTimeout: 1200 * time.Millisecond,
		Backoff:           50 * time.Millisecond,
	}

	res := verifyTunnel(context.Background(), addr, policy)
	if res.OK {
		t.Fatalf("black-hole tunnel reported as healthy: %+v", res)
	}
	if res.Attempts != policy.Attempts {
		t.Fatalf("expected %d attempts, got %d", policy.Attempts, res.Attempts)
	}
	if res.Err == nil {
		t.Fatal("expected an error describing the failure")
	}
}

func TestVerifyTunnelRejectsMissingSocks(t *testing.T) {
	res := verifyTunnel(context.Background(), "", VerifyPolicy{})
	if res.OK {
		t.Fatal("empty SOCKS endpoint must not be reported as verified")
	}
	if res.Err == nil || !strings.Contains(res.Err.Error(), "SOCKS") {
		t.Fatalf("expected a SOCKS-related error, got %v", res.Err)
	}
}

// A dead port is the other real shape: the core exited or never bound.
func TestVerifyTunnelDetectsClosedPort(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	_ = ln.Close() // nothing is listening now

	res := verifyTunnel(context.Background(), addr, VerifyPolicy{
		Attempts:          2,
		PerAttemptTimeout: 800 * time.Millisecond,
		Backoff:           20 * time.Millisecond,
	})
	if res.OK {
		t.Fatalf("closed port reported as healthy: %+v", res)
	}
}

func TestVerifyTunnelHonoursContextCancellation(t *testing.T) {
	addr, stop := startBlackHoleSOCKS(t)
	defer stop()

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled before the first attempt

	res := verifyTunnel(ctx, addr, VerifyPolicy{Attempts: 5})
	if res.OK {
		t.Fatal("cancelled verification must not report success")
	}
	if !errors.Is(res.Err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", res.Err)
	}
}

func TestVerifyPolicyDefaults(t *testing.T) {
	p := VerifyPolicy{}.withDefaults()
	if p.Attempts <= 0 || p.PerAttemptTimeout <= 0 || p.Backoff <= 0 {
		t.Fatalf("defaults must be positive, got %+v", p)
	}
}

func TestDescribeVerifyFailureMentionsAttempts(t *testing.T) {
	msg := describeVerifyFailure(VerifyResult{Attempts: 3, Err: errors.New("boom")})
	if !strings.Contains(msg, "3") || !strings.Contains(msg, "boom") {
		t.Fatalf("failure description must carry attempts and cause, got %q", msg)
	}
	// The message is user-visible, so it must explain the situation rather
	// than leak an opaque code.
	if !strings.Contains(strings.ToLower(msg), "no traffic") {
		t.Fatalf("failure description should state the tunnel carried no traffic, got %q", msg)
	}
}
