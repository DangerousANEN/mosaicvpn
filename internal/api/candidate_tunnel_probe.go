package api

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/proxy"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/state"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

const (
	// ProbeKindIsolatedHTTPS204 is the canonical probeKind for isolated tunnel checks.
	ProbeKindIsolatedHTTPS204 = "isolated_socks_https204"

	// DefaultCandidateProbeURL is the canonical high-availability 204 endpoint.
	DefaultCandidateProbeURL = "https://cp.cloudflare.com/generate_204"

	// MaxConcurrentCandidateProbes bounds child sing-box processes globally.
	MaxConcurrentCandidateProbes = 4
)

// approvedProductionEndpoints is the strict static allowlist for HTTPS exact-204 probes.
var approvedProductionEndpoints = map[string]bool{
	"https://cp.cloudflare.com/generate_204":             true,
	"https://www.gstatic.com/generate_204":               true,
	"https://connectivitycheck.gstatic.com/generate_204": true,
}

// Unexported test dependency seams. No test bypass is exported on the production surface.
var (
	candidateProbeSem = make(chan struct{}, MaxConcurrentCandidateProbes)

	testOverrideMu         sync.RWMutex
	testInjectedAllowLocal bool
	testInjectedTargetURL  string
	testInjectedTLSConfig  *tls.Config
)

// ValidateCandidateProbeURL validates the probe target URL.
// In production, it enforces a strict static allowlist of HTTPS 204 endpoints and
// disallows custom ports, user credentials, queries, and fragments to prevent SSRF and DNS rebinding.
func ValidateCandidateProbeURL(rawURL string, allowLocal bool) (*url.URL, error) {
	if rawURL == "" {
		rawURL = DefaultCandidateProbeURL
	}
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, fmt.Errorf("invalid probe url %q: %w", rawURL, err)
	}

	if !strings.EqualFold(u.Scheme, "https") {
		return nil, fmt.Errorf("probe url %q rejected: scheme must be https", rawURL)
	}

	if u.User != nil {
		return nil, fmt.Errorf("probe url %q rejected: userinfo not permitted", rawURL)
	}
	if u.RawQuery != "" {
		return nil, fmt.Errorf("probe url %q rejected: query string not permitted", rawURL)
	}
	if u.Fragment != "" {
		return nil, fmt.Errorf("probe url %q rejected: fragment not permitted", rawURL)
	}

	if allowLocal {
		if u.Hostname() == "" {
			return nil, fmt.Errorf("probe url %q has empty host", rawURL)
		}
		return u, nil
	}

	// In production, enforce standard HTTPS port (no custom ports)
	if u.Port() != "" && u.Port() != "443" {
		return nil, fmt.Errorf("probe url %q rejected: custom port not permitted in production", rawURL)
	}

	// Canonicalize for lookup
	canonicalURL := fmt.Sprintf("https://%s%s", strings.ToLower(u.Hostname()), u.EscapedPath())
	if !approvedProductionEndpoints[canonicalURL] {
		return nil, fmt.Errorf("probe url %q rejected: not in approved production allowlist", rawURL)
	}

	return u, nil
}

// BuildIsolatedProbeConfig generates a strict, leak-free sing-box config
// where ALL traffic routes exclusively through the candidate outbound.
// The generated config strictly retains ONLY the authenticated proxy candidate,
// stripping any direct, block, or detour configuration so no traffic can escape.
func BuildIsolatedProbeConfig(server proto.Server, socksPort int) ([]byte, error) {
	cfgBlob, err := state.BuildSingBoxConfig(
		server,
		socksPort,
		0,
		store.Prefs{TunnelMode: "proxy"},
		nil,
		proto.DNSConfig{Mode: "disabled"},
		0,
		"",
	)
	if err != nil {
		return nil, fmt.Errorf("build config: %w", err)
	}

	var root map[string]any
	if err := json.Unmarshal(cfgBlob, &root); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}

	// Ensure route.final points strictly to proxy candidate and all routing rules are stripped
	// so no traffic can ever escape to 'direct'.
	root["route"] = map[string]any{
		"final": "proxy",
		"rules": []any{},
	}

	// Restrict inbounds strictly to the single loopback SOCKS inbound
	root["inbounds"] = []any{
		map[string]any{
			"type":        "socks",
			"tag":         "socks-in",
			"listen":      "127.0.0.1",
			"listen_port": socksPort,
		},
	}

	// Locate the authenticated candidate outbound with tag "proxy".
	// The configuration must strictly contain ONLY this single authenticated proxy candidate outbound.
	var candidateOutbound map[string]any
	if outbounds, ok := root["outbounds"].([]any); ok {
		for _, ob := range outbounds {
			if m, ok := ob.(map[string]any); ok {
				if tag, _ := m["tag"].(string); tag == "proxy" {
					candidateOutbound = m
					break
				}
			}
		}
	}
	if candidateOutbound == nil {
		return nil, fmt.Errorf("no proxy candidate outbound found in generated config")
	}

	// Strip any detour configuration so candidate cannot detour to direct or another outbound
	delete(candidateOutbound, "detour")

	// Retain strictly and exclusively the single authenticated proxy candidate outbound.
	// No direct, no block, and no detour outbounds are permitted.
	root["outbounds"] = []any{candidateOutbound}

	return json.MarshalIndent(root, "", "  ")
}

// ProbeCandidateIsolated executes an isolated, authenticated sing-box SOCKS candidate
// HTTPS 204 check with bounded global concurrency and complete context cleanup.
// It never touches the active tunnel and never falls back to direct unauthenticated HTTP or plain TCP.
func ProbeCandidateIsolated(ctx context.Context, groupID string, server proto.Server, probeURL string, samples int) proto.CandidateProbeResult {
	if samples < 3 {
		samples = 3
	}
	if samples > 20 {
		samples = 20
	}

	result := proto.CandidateProbeResult{
		GroupID:     groupID,
		CandidateID: server.ID,
		Samples:     0, // Count only HTTP requests actually attempted.
		CheckedAt:   time.Now().UTC(),
		ProbeKind:   ProbeKindIsolatedHTTPS204,
		LossPercent: 100.0,
	}

	if ctx.Err() != nil {
		result.ProbeKind = "cancelled"
		return result
	}

	testOverrideMu.RLock()
	allowLocal := testInjectedAllowLocal
	injectedURL := testInjectedTargetURL
	injectedTLS := testInjectedTLSConfig
	testOverrideMu.RUnlock()

	if injectedURL != "" {
		probeURL = injectedURL
	} else if probeURL == "" {
		probeURL = DefaultCandidateProbeURL
	}

	parsedURL, err := ValidateCandidateProbeURL(probeURL, allowLocal)
	if err != nil {
		result.ProbeKind = "policy_rejected"
		return result
	}

	// Acquire the global bounded semaphore BEFORE the binary lookup: pool
	// saturation is a transient runtime state that must be reported as
	// `concurrency_timeout` even on hosts without a probe binary installed
	// (otherwise CI without sing-box always reports `binary_missing`).
	select {
	case candidateProbeSem <- struct{}{}:
		defer func() { <-candidateProbeSem }()
	case <-ctx.Done():
		result.ProbeKind = "concurrency_timeout"
		return result
	}

	bin := state.LocateSingBox()
	if bin == "" {
		result.ProbeKind = "binary_missing"
		return result
	}

	// Bound total execution deadline for this candidate probe
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	socksPort, err := freeLoopbackPort()
	if err != nil {
		result.ProbeKind = "port_error"
		return result
	}

	cfgBlob, err := BuildIsolatedProbeConfig(server, socksPort)
	if err != nil {
		result.ProbeKind = "config_error"
		return result
	}

	tmpDir, err := os.MkdirTemp("", "mosaic-cand-probe-*")
	if err != nil {
		result.ProbeKind = "tmp_error"
		return result
	}
	defer os.RemoveAll(tmpDir)

	cfgPath := filepath.Join(tmpDir, "config.json")
	if err := os.WriteFile(cfgPath, cfgBlob, 0o600); err != nil {
		result.ProbeKind = "write_error"
		return result
	}

	cmd := exec.CommandContext(ctx, bin, "run", "-c", cfgPath)
	if err := cmd.Start(); err != nil {
		result.ProbeKind = "start_error"
		return result
	}
	defer func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	socksAddr := fmt.Sprintf("127.0.0.1:%d", socksPort)
	if err := waitForLoopbackPort(ctx, socksAddr, 3*time.Second); err != nil {
		result.ProbeKind = "socks_unavailable"
		return result
	}

	sampleTimeout := 2 * time.Second
	dialer, err := proxy.SOCKS5("tcp", socksAddr, nil, &net.Dialer{Timeout: sampleTimeout})
	if err != nil {
		result.ProbeKind = "socks_dialer_error"
		return result
	}

	contextDialer, ok := dialer.(proxy.ContextDialer)
	if !ok {
		result.ProbeKind = "context_dialer_unsupported"
		return result
	}

	tlsClientConfig := &tls.Config{
		MinVersion: tls.VersionTLS12,
	}
	if injectedTLS != nil {
		tlsClientConfig = injectedTLS
	}

	transport := &http.Transport{
		DialContext: func(c context.Context, network, addr string) (net.Conn, error) {
			return contextDialer.DialContext(c, network, addr)
		},
		Proxy:                  nil, // Explicitly nil: ignore HTTP_PROXY, HTTPS_PROXY, NO_PROXY
		TLSClientConfig:        tlsClientConfig,
		DisableKeepAlives:      true,
		TLSHandshakeTimeout:    sampleTimeout,
		ResponseHeaderTimeout:  sampleTimeout,
		MaxResponseHeaderBytes: 16 * 1024, // 16 KiB bound
	}
	defer transport.CloseIdleConnections()

	httpClient := &http.Client{
		Transport: transport,
		Timeout:   sampleTimeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return fmt.Errorf("candidate probe redirect prohibited: %s", req.URL.String())
		},
	}

	targetStr := parsedURL.String()
	var latencies []int

	for i := 0; i < samples; i++ {
		if ctx.Err() != nil {
			break
		}

		reqCtx, reqCancel := context.WithTimeout(ctx, sampleTimeout)
		req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, targetStr, nil)
		if err != nil {
			reqCancel()
			continue
		}

		result.Samples++
		start := time.Now()
		resp, err := httpClient.Do(req)
		elapsed := int(time.Since(start).Milliseconds())
		reqCancel()

		if resp != nil && resp.Body != nil {
			_ = resp.Body.Close()
		}
		if err != nil {
			continue
		}

		// STRICT: Only exact HTTP 204 No Content certifies candidate reachability.
		// HTTP 200 (captive portal/auth wall/block page), 30x, 40x, 50x are strictly rejected.
		if resp.StatusCode == http.StatusNoContent {
			if elapsed < 1 {
				elapsed = 1
			}
			latencies = append(latencies, elapsed)
		}
	}

	median, p95, jitter := computeProbeStats(latencies)
	result.Successes = len(latencies)
	if result.Samples > 0 {
		result.LossPercent = float64(result.Samples-len(latencies)) * 100.0 / float64(result.Samples)
	}
	result.MedianLatencyMs = median
	result.P95LatencyMs = p95
	result.JitterMs = jitter
	result.Successful = ctx.Err() == nil && result.Samples == samples && len(latencies) > 0 && result.LossPercent < 50.0
	if ctx.Err() != nil {
		result.ProbeKind = "cancelled"
	}

	return result
}

func freeLoopbackPort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, fmt.Errorf("listen free port: %w", err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port, nil
}

func waitForLoopbackPort(ctx context.Context, addr string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		c, err := net.DialTimeout("tcp", addr, 250*time.Millisecond)
		if err == nil {
			_ = c.Close()
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("timeout waiting for %s", addr)
}
