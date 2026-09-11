package state

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"time"

	"golang.org/x/net/proxy"

	"github.com/pupspochta-cpu/mosaicvpn/internal/logx"
	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

// Runtime truth-check.
//
// WHY THIS EXISTS
// ---------------
// Until now the daemon announced StateConnected the instant backend.Start()
// returned nil. That is a promise the core cannot keep: "the process started"
// is not "traffic flows". Two shipped incidents came from exactly this gap:
//
//   - sing-box multiplex against an Xray server: the config validates, the
//     core starts, the UI turns green, and every stream is silently dropped
//     (the core dials sp.mux.sing-box.arpa, which the peer does not speak).
//   - a legacy DNS server entry that made part of the resolution path bypass
//     the tunnel while the session still looked healthy.
//
// For a VPN a silent failure is worse than a loud one. A user who sees an
// error retries; a user who sees a green shield keeps browsing while their
// traffic goes nowhere — or worse, goes out unprotected. So before the
// session is called connected we push real bytes through the tunnel and
// require a real answer.
//
// WHAT IS CHECKED
// ---------------
// A plain HTTP request over the tunnel's SOCKS endpoint to a small, stable
// endpoint. Success requires an actual HTTP response — not a TCP handshake,
// not an ICMP echo, both of which a black-holing proxy can still satisfy.

// verifyProbeTargets are tiny, highly-available endpoints. The list is tried
// in order; the first success wins. They are deliberately plain HTTP-over-TLS
// endpoints that return a minimal body, so the probe costs a few hundred bytes.
var verifyProbeTargets = []string{
	"https://cp.cloudflare.com/generate_204",
	"https://www.gstatic.com/generate_204",
	"https://captive.apple.com/hotspot-detect.html",
}

// VerifyPolicy bounds the truth-check. Zero values fall back to defaults so
// callers can pass an empty struct.
type VerifyPolicy struct {
	// Attempts is how many probe rounds to run before declaring failure.
	Attempts int
	// PerAttemptTimeout bounds a single probe request.
	PerAttemptTimeout time.Duration
	// Backoff is the pause between failed attempts. A freshly started core
	// may need a moment before its outbound is ready, so a failed first
	// attempt is normal and must not condemn the session.
	Backoff time.Duration
}

func (p VerifyPolicy) withDefaults() VerifyPolicy {
	if p.Attempts <= 0 {
		p.Attempts = 3
	}
	if p.PerAttemptTimeout <= 0 {
		p.PerAttemptTimeout = 6 * time.Second
	}
	if p.Backoff <= 0 {
		p.Backoff = 1500 * time.Millisecond
	}
	return p
}

// VerifyResult records what the truth-check observed. It is intentionally
// descriptive: when a probe fails the user (and the log) should learn which
// endpoint was tried and how, not merely that "something went wrong".
type VerifyResult struct {
	OK        bool
	Target    string
	LatencyMS int
	Attempts  int
	Err       error
}

// TunnelVerifier is implemented by backends that expose a loopback SOCKS
// endpoint. Any ProxyListener already satisfies this shape; the alias exists
// to make the dependency of the verifier explicit at the call site.
type TunnelVerifier interface {
	Proxies() (socks, http string)
}

// verifyTunnel pushes a real request through the tunnel's SOCKS endpoint and
// reports whether the tunnel actually carries traffic.
//
// It returns OK=false rather than an error for a failed probe: a probe that
// says "no traffic" is a successful measurement of a broken tunnel, and the
// caller decides what to do about it.
func verifyTunnel(ctx context.Context, socks string, policy VerifyPolicy) VerifyResult {
	policy = policy.withDefaults()
	if socks == "" {
		return VerifyResult{Err: errors.New("backend exposes no SOCKS endpoint")}
	}

	var lastErr error
	for attempt := 1; attempt <= policy.Attempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return VerifyResult{Attempts: attempt, Err: err}
		}

		target := verifyProbeTargets[(attempt-1)%len(verifyProbeTargets)]
		start := time.Now()
		err := probeOnce(ctx, socks, target, policy.PerAttemptTimeout)
		if err == nil {
			return VerifyResult{
				OK:        true,
				Target:    target,
				LatencyMS: int(time.Since(start).Milliseconds()),
				Attempts:  attempt,
			}
		}
		lastErr = err
		logx.Warn("tunnel verification attempt failed",
			"attempt", attempt, "target", target, "latency_ms", time.Since(start).Milliseconds(), "err", err)

		if attempt < policy.Attempts {
			select {
			case <-ctx.Done():
				return VerifyResult{Attempts: attempt, Err: ctx.Err()}
			case <-time.After(policy.Backoff):
			}
		}
	}

	return VerifyResult{Attempts: policy.Attempts, Err: lastErr}
}

// probeOnce performs a single HTTP request through the SOCKS endpoint.
func probeOnce(ctx context.Context, socks, target string, timeout time.Duration) error {
	dialer, err := proxy.SOCKS5("tcp", socks, nil, &net.Dialer{Timeout: timeout})
	if err != nil {
		return fmt.Errorf("socks5 dialer: %w", err)
	}

	transport := &http.Transport{
		DialContext: func(_ context.Context, network, addr string) (net.Conn, error) {
			return dialer.Dial(network, addr)
		},
		// A fresh connection every probe: a pooled one could mask a tunnel
		// that has died since the previous check.
		DisableKeepAlives:   true,
		TLSHandshakeTimeout: timeout,
	}
	client := &http.Client{
		Transport: transport,
		Timeout:   timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	reqCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, target, nil)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	// Any HTTP status proves bytes made a round trip through the tunnel and a
	// real server answered. We are testing reachability, not the endpoint's
	// own health, so a 4xx/5xx from a captive-portal endpoint still counts.
	if resp.StatusCode <= 0 {
		return fmt.Errorf("invalid response status %d", resp.StatusCode)
	}
	return nil
}

// verifyActiveTunnel runs the truth-check against whichever backend is live.
// Backends that expose no proxy endpoint (mock/embedded) cannot be probed this
// way and are trusted, so tests and platform backends keep working unchanged.
func (m *Manager) verifyActiveTunnel(ctx context.Context, policy VerifyPolicy) VerifyResult {
	m.mu.Lock()
	backend := m.backend
	m.mu.Unlock()

	listener, ok := backend.(ProxyListener)
	if !ok {
		return VerifyResult{OK: true, Attempts: 0, Target: "skipped:no-proxy-listener"}
	}
	socks, _ := listener.Proxies()
	if socks == "" {
		return VerifyResult{OK: true, Attempts: 0, Target: "skipped:no-socks"}
	}
	return verifyTunnel(ctx, socks, policy)
}

// describeVerifyFailure renders an operator- and user-readable reason.
func describeVerifyFailure(res VerifyResult) string {
	if res.Err != nil {
		return fmt.Sprintf(
			"tunnel started but carried no traffic after %d attempt(s): %v",
			res.Attempts, res.Err)
	}
	return fmt.Sprintf("tunnel started but carried no traffic after %d attempt(s)",
		res.Attempts)
}

var _ = proto.StateVerifying
