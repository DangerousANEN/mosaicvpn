package api

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/state"
)

// SetInjectedCandidateProbeTargetForTest allows unit tests in this package to inject
// a local TLS endpoint without exposing any bypass mechanism on the production API surface.
func SetInjectedCandidateProbeTargetForTest(targetURL string, tlsConfig *tls.Config) func() {
	testOverrideMu.Lock()
	testInjectedAllowLocal = true
	testInjectedTargetURL = targetURL
	testInjectedTLSConfig = tlsConfig
	testOverrideMu.Unlock()

	return func() {
		testOverrideMu.Lock()
		testInjectedAllowLocal = false
		testInjectedTargetURL = ""
		testInjectedTLSConfig = nil
		testOverrideMu.Unlock()
	}
}

func resolveTestSingBox(t *testing.T) string {
	t.Helper()
	for _, rel := range []string{
		filepath.Join("..", "..", "build", "sing-box.exe"),
		filepath.Join("build", "sing-box.exe"),
		filepath.Join("..", "..", "build", "sing-box"),
		filepath.Join("build", "sing-box"),
	} {
		if fi, err := os.Stat(rel); err == nil && !fi.IsDir() {
			if abs, err := filepath.Abs(rel); err == nil {
				absDir := filepath.Dir(abs)
				_ = os.Setenv("PATH", absDir+string(os.PathListSeparator)+os.Getenv("PATH"))
				return abs
			}
		}
	}
	if bin := state.LocateSingBox(); bin != "" {
		return bin
	}
	return ""
}

func TestValidateCandidateProbeURL_PolicyValidation(t *testing.T) {
	tests := []struct {
		name       string
		url        string
		allowLocal bool
		wantErr    bool
	}{
		{"default empty falls back to cloudflare 204", "", false, false},
		{"plain http rejected", "http://cp.cloudflare.com/generate_204", false, true},
		{"approved cloudflare 204 allowed", "https://cp.cloudflare.com/generate_204", false, false},
		{"approved gstatic 204 allowed", "https://www.gstatic.com/generate_204", false, false},
		{"approved connectivitycheck allowed", "https://connectivitycheck.gstatic.com/generate_204", false, false},
		{"arbitrary internet url rejected in prod", "https://example.com/generate_204", false, true},
		{"custom port rejected in prod", "https://cp.cloudflare.com:8443/generate_204", false, true},
		{"userinfo rejected in prod", "https://user:pass@cp.cloudflare.com/generate_204", false, true},
		{"query params rejected in prod", "https://cp.cloudflare.com/generate_204?q=1", false, true},
		{"fragment rejected in prod", "https://cp.cloudflare.com/generate_204#tag", false, true},
		{"localhost rejected in prod", "https://localhost/generate_204", false, true},
		{"loopback ip rejected in prod", "https://127.0.0.1:8443/generate_204", false, true},
		{"private ip rejected in prod", "https://192.168.1.1/generate_204", false, true},
		{"local allowed when flag enabled", "https://127.0.0.1:8443/204", true, false},
		{"localhost allowed when flag enabled", "https://localhost:8443/204", true, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			u, err := ValidateCandidateProbeURL(tt.url, tt.allowLocal)
			if (err != nil) != tt.wantErr {
				t.Errorf("ValidateCandidateProbeURL(%q, allowLocal=%v) err = %v, wantErr = %v", tt.url, tt.allowLocal, err, tt.wantErr)
			}
			if err == nil && u == nil {
				t.Errorf("ValidateCandidateProbeURL(%q) returned nil url without error", tt.url)
			}
		})
	}
}

func TestBuildIsolatedProbeConfig_StrictlyNoDirectOrDetour(t *testing.T) {
	server := proto.Server{
		ID:       "node-strict",
		Name:     "Strict Node",
		Protocol: proto.ProtoVLESS,
		Address:  "198.51.100.40",
		Port:     443,
		Raw: map[string]any{
			"uuid":     "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
			"network":  "ws",
			"path":     "/ws",
			"security": "tls",
			"detour":   "direct", // malicious or accidental detour
		},
	}

	socksPort := 10800
	cfgBlob, err := BuildIsolatedProbeConfig(server, socksPort)
	if err != nil {
		t.Fatalf("BuildIsolatedProbeConfig failed: %v", err)
	}

	var parsed map[string]any
	if err := json.Unmarshal(cfgBlob, &parsed); err != nil {
		t.Fatalf("unmarshal generated config: %v", err)
	}

	// 1. Verify inbounds: strictly single socks loopback inbound
	inbounds, ok := parsed["inbounds"].([]any)
	if !ok || len(inbounds) != 1 {
		t.Fatalf("expected exactly 1 inbound, got %d", len(inbounds))
	}
	inboundMap, _ := inbounds[0].(map[string]any)
	if inboundMap["type"] != "socks" || inboundMap["listen"] != "127.0.0.1" {
		t.Errorf("unexpected inbound: %+v", inboundMap)
	}

	// 2. Verify outbounds: strictly ONLY the single authenticated proxy candidate
	outbounds, ok := parsed["outbounds"].([]any)
	if !ok || len(outbounds) != 1 {
		t.Fatalf("expected exactly 1 outbound, got %d: %+v", len(outbounds), outbounds)
	}
	outboundMap, _ := outbounds[0].(map[string]any)
	if outboundMap["tag"] != "proxy" {
		t.Errorf("expected tag 'proxy', got %v", outboundMap["tag"])
	}
	if outboundMap["type"] != "vless" {
		t.Errorf("expected type 'vless', got %v", outboundMap["type"])
	}

	// 3. Ensure NO detour exists in the outbound configuration
	if detour, exists := outboundMap["detour"]; exists && detour != nil && detour != "" {
		t.Errorf("detour must be stripped from candidate outbound, found: %v", detour)
	}

	// 4. Ensure route: final is 'proxy', rules is empty
	routeMap, _ := parsed["route"].(map[string]any)
	if routeMap["final"] != "proxy" {
		t.Errorf("expected route.final 'proxy', got %v", routeMap["final"])
	}
	rules, _ := routeMap["rules"].([]any)
	if len(rules) != 0 {
		t.Errorf("expected 0 route rules, got %d", len(rules))
	}

	// 5. Virtual group must be rejected
	vgServer := proto.Server{
		ID:             "vg-1",
		IsVirtualGroup: true,
	}
	if _, err := BuildIsolatedProbeConfig(vgServer, socksPort); err == nil {
		t.Errorf("expected error for virtual group candidate, got nil")
	}
}

func generateProbeTestCert(t *testing.T, dir string) (string, string) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}

	notBefore := time.Now().Add(-1 * time.Hour)
	notAfter := notBefore.Add(24 * time.Hour)

	serialNumberLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serialNumber, err := rand.Int(rand.Reader, serialNumberLimit)
	if err != nil {
		t.Fatalf("generate serial: %v", err)
	}

	template := x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			Organization: []string{"MosaicVPN Probe Test"},
			CommonName:   "127.0.0.1",
		},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1")},
		DNSNames:              []string{"localhost"},
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}

	certPath := filepath.Join(dir, "cert.pem")
	certOut, err := os.Create(certPath)
	if err != nil {
		t.Fatalf("create cert file: %v", err)
	}
	_ = pem.Encode(certOut, &pem.Block{Type: "CERTIFICATE", Bytes: derBytes})
	_ = certOut.Close()

	keyBytes, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	keyPath := filepath.Join(dir, "key.pem")
	keyOut, err := os.Create(keyPath)
	if err != nil {
		t.Fatalf("create key file: %v", err)
	}
	_ = pem.Encode(keyOut, &pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes})
	_ = keyOut.Close()

	return certPath, keyPath
}

func startRealSingBoxVLESSServer(t *testing.T, bin, validUUID string) (int, func()) {
	t.Helper()
	dir := t.TempDir()
	certPath, keyPath := generateProbeTestCert(t, dir)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen port: %v", err)
	}
	srvPort := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()

	srvCfg := map[string]any{
		"log": map[string]any{"level": "error"},
		"inbounds": []any{
			map[string]any{
				"type":        "vless",
				"tag":         "vless-in",
				"listen":      "127.0.0.1",
				"listen_port": srvPort,
				"users": []any{
					map[string]any{"uuid": validUUID},
				},
				"tls": map[string]any{
					"enabled":          true,
					"certificate_path": certPath,
					"key_path":         keyPath,
				},
				"transport": map[string]any{
					"type": "ws",
					"path": "/ws",
				},
			},
		},
		"outbounds": []any{
			map[string]any{
				"type": "direct",
				"tag":  "direct",
			},
		},
	}
	cfgBlob, err := json.Marshal(srvCfg)
	if err != nil {
		t.Fatalf("marshal srv config: %v", err)
	}
	srvCfgPath := filepath.Join(dir, "srv.json")
	if err := os.WriteFile(srvCfgPath, cfgBlob, 0o600); err != nil {
		t.Fatalf("write srv config: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, bin, "run", "-c", srvCfgPath)
	if err := cmd.Start(); err != nil {
		cancel()
		t.Fatalf("start test vless server: %v", err)
	}

	addr := fmt.Sprintf("127.0.0.1:%d", srvPort)
	if err := waitForLoopbackPort(ctx, addr, 5*time.Second); err != nil {
		cancel()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
		t.Fatalf("wait for vless server: %v", err)
	}

	return srvPort, func() {
		cancel()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}
}

func TestProbeCandidateIsolated_RealFixtureCredentialsAnd200Rejection(t *testing.T) {
	bin := resolveTestSingBox(t)
	if bin == "" {
		t.Skip("sing-box binary not found")
	}

	validUUID := "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
	invalidUUID := "00000000-0000-0000-0000-000000000000"

	srvPort, cleanupServer := startRealSingBoxVLESSServer(t, bin, validUUID)
	defer cleanupServer()

	// Injected HTTPS 204 server (simulating legitimate check 204 endpoint)
	ts204 := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer ts204.Close()

	// Injected HTTPS 200 server (simulating captive portal / MITM / auth page)
	ts200 := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("<html>Captive Portal</html>"))
	}))
	defer ts200.Close()

	// Replace InsecureSkipVerify:true with trusted x509 root pool containing the httptest cert.
	// This proves true certificate validity without skipping TLS verification.
	certPool := x509.NewCertPool()
	certPool.AddCert(ts204.Certificate())
	certPool.AddCert(ts200.Certificate())

	tlsConfig := &tls.Config{
		RootCAs:            certPool,
		InsecureSkipVerify: false,
		MinVersion:         tls.VersionTLS12,
	}

	buildServer := func(id, uuid string) proto.Server {
		return proto.Server{
			ID:       id,
			Name:     "Test Node",
			Protocol: proto.ProtoVLESS,
			Address:  "127.0.0.1",
			Port:     srvPort,
			Raw: map[string]any{
				"uuid":        uuid,
				"network":     "ws",
				"path":        "/ws",
				"security":    "tls",
				"sni":         "localhost",
				"insecure":    "true",
				"fingerprint": "chrome",
			},
		}
	}

	t.Run("GoodCredentials_Exact204_Succeeds", func(t *testing.T) {
		cleanup := SetInjectedCandidateProbeTargetForTest(ts204.URL, tlsConfig)
		defer cleanup()

		server := buildServer("node-good", validUUID)
		res := ProbeCandidateIsolated(context.Background(), "grp-1", server, ts204.URL, 3)

		if !res.Successful {
			t.Fatalf("expected successful probe, got result: %+v", res)
		}
		if res.Successes != 3 {
			t.Errorf("expected 3 successes, got %d", res.Successes)
		}
		if res.ProbeKind != ProbeKindIsolatedHTTPS204 {
			t.Errorf("expected probeKind %q, got %q", ProbeKindIsolatedHTTPS204, res.ProbeKind)
		}
	})

	t.Run("BadCredentials_Rejected", func(t *testing.T) {
		cleanup := SetInjectedCandidateProbeTargetForTest(ts204.URL, tlsConfig)
		defer cleanup()

		server := buildServer("node-bad-creds", invalidUUID)
		res := ProbeCandidateIsolated(context.Background(), "grp-1", server, ts204.URL, 3)

		if res.Successful {
			t.Fatalf("expected failed probe for bad credentials, got successful: %+v", res)
		}
		if res.Successes != 0 {
			t.Errorf("expected 0 successes, got %d", res.Successes)
		}
	})

	t.Run("HTTP200_StrictlyRejected", func(t *testing.T) {
		cleanup := SetInjectedCandidateProbeTargetForTest(ts200.URL, tlsConfig)
		defer cleanup()

		// Good credentials, but target returns HTTP 200 instead of HTTP 204
		server := buildServer("node-http200", validUUID)
		res := ProbeCandidateIsolated(context.Background(), "grp-1", server, ts200.URL, 3)

		if res.Successful {
			t.Fatalf("expected failed probe when target returns 200, got successful: %+v", res)
		}
		if res.Successes != 0 {
			t.Errorf("expected 0 successes for HTTP 200, got %d", res.Successes)
		}
	})

	t.Run("CanceledContext_TerminatesCleanly", func(t *testing.T) {
		cleanup := SetInjectedCandidateProbeTargetForTest(ts204.URL, tlsConfig)
		defer cleanup()

		ctx, cancel := context.WithCancel(context.Background())
		cancel() // pre-canceled context

		server := buildServer("node-canceled", validUUID)
		res := ProbeCandidateIsolated(ctx, "grp-1", server, ts204.URL, 3)

		if res.Successful {
			t.Errorf("expected pre-canceled context probe to fail, got success: %+v", res)
		}
	})
}

func TestProbeCandidateIsolated_UntrustedCertRejection(t *testing.T) {
	bin := resolveTestSingBox(t)
	if bin == "" {
		t.Skip("sing-box binary not found")
	}

	validUUID := "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
	srvPort, cleanupServer := startRealSingBoxVLESSServer(t, bin, validUUID)
	defer cleanupServer()

	// Server presenting a certificate NOT in the client's trusted root pool
	tsUntrusted := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer tsUntrusted.Close()

	// Empty cert pool: neither system nor tsUntrusted cert is trusted
	emptyPool := x509.NewCertPool()
	untrustedTLS := &tls.Config{
		RootCAs:            emptyPool,
		InsecureSkipVerify: false,
		MinVersion:         tls.VersionTLS12,
	}

	cleanup := SetInjectedCandidateProbeTargetForTest(tsUntrusted.URL, untrustedTLS)
	defer cleanup()

	server := proto.Server{
		ID:       "node-untrusted-cert",
		Name:     "Untrusted Cert Node",
		Protocol: proto.ProtoVLESS,
		Address:  "127.0.0.1",
		Port:     srvPort,
		Raw: map[string]any{
			"uuid":        validUUID,
			"network":     "ws",
			"path":        "/ws",
			"security":    "tls",
			"sni":         "localhost",
			"insecure":    "true",
			"fingerprint": "chrome",
		},
	}

	res := ProbeCandidateIsolated(context.Background(), "grp-1", server, tsUntrusted.URL, 3)
	if res.Successful {
		t.Fatalf("expected untrusted certificate to be strictly rejected, got success: %+v", res)
	}
	if res.Successes != 0 {
		t.Errorf("expected 0 successes for untrusted cert, got %d", res.Successes)
	}
	if res.LossPercent != 100.0 {
		t.Errorf("expected 100%% loss for untrusted cert, got %v", res.LossPercent)
	}
}

func TestProbeCandidateIsolated_RedirectRejection(t *testing.T) {
	bin := resolveTestSingBox(t)
	if bin == "" {
		t.Skip("sing-box binary not found")
	}

	validUUID := "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
	srvPort, cleanupServer := startRealSingBoxVLESSServer(t, bin, validUUID)
	defer cleanupServer()

	var redirectTargetHits atomic.Int64
	tsFinalTarget := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		redirectTargetHits.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer tsFinalTarget.Close()

	// Redirect server bouncing to tsFinalTarget (e.g. captive portal redirect)
	tsRedirect := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, tsFinalTarget.URL, http.StatusFound)
	}))
	defer tsRedirect.Close()

	pool := x509.NewCertPool()
	pool.AddCert(tsFinalTarget.Certificate())
	pool.AddCert(tsRedirect.Certificate())

	tlsConfig := &tls.Config{
		RootCAs:            pool,
		InsecureSkipVerify: false,
		MinVersion:         tls.VersionTLS12,
	}

	cleanup := SetInjectedCandidateProbeTargetForTest(tsRedirect.URL, tlsConfig)
	defer cleanup()

	server := proto.Server{
		ID:       "node-redirect",
		Name:     "Redirect Node",
		Protocol: proto.ProtoVLESS,
		Address:  "127.0.0.1",
		Port:     srvPort,
		Raw: map[string]any{
			"uuid":        validUUID,
			"network":     "ws",
			"path":        "/ws",
			"security":    "tls",
			"sni":         "localhost",
			"insecure":    "true",
			"fingerprint": "chrome",
		},
	}

	res := ProbeCandidateIsolated(context.Background(), "grp-1", server, tsRedirect.URL, 3)
	if res.Successful {
		t.Fatalf("expected redirect to be rejected, got success: %+v", res)
	}
	if res.Successes != 0 {
		t.Errorf("expected 0 successes on redirect, got %d", res.Successes)
	}
	// Verify that redirect target was NOT followed
	if hits := redirectTargetHits.Load(); hits != 0 {
		t.Errorf("redirect was followed: expected 0 hits on redirect destination, got %d", hits)
	}
}

func TestProbeCandidateIsolated_ProxyEnvIgnored_ZeroHitsOnBadCreds(t *testing.T) {
	bin := resolveTestSingBox(t)
	if bin == "" {
		t.Skip("sing-box binary not found")
	}

	validUUID := "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
	invalidUUID := "00000000-0000-0000-0000-000000000000"

	srvPort, cleanupServer := startRealSingBoxVLESSServer(t, bin, validUUID)
	defer cleanupServer()

	var targetHits atomic.Int64
	tsTarget := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		targetHits.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer tsTarget.Close()

	pool := x509.NewCertPool()
	pool.AddCert(tsTarget.Certificate())

	tlsConfig := &tls.Config{
		RootCAs:            pool,
		InsecureSkipVerify: false,
		MinVersion:         tls.VersionTLS12,
	}

	cleanup := SetInjectedCandidateProbeTargetForTest(tsTarget.URL, tlsConfig)
	defer cleanup()

	// Set host proxy and bypass environment variables.
	// The isolated candidate probe MUST ignore these completely.
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:59999")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:59999")
	t.Setenv("ALL_PROXY", "http://127.0.0.1:59999")
	t.Setenv("NO_PROXY", "127.0.0.1,localhost")

	buildServer := func(id, uuid string) proto.Server {
		return proto.Server{
			ID:       id,
			Name:     "Test Node",
			Protocol: proto.ProtoVLESS,
			Address:  "127.0.0.1",
			Port:     srvPort,
			Raw: map[string]any{
				"uuid":        uuid,
				"network":     "ws",
				"path":        "/ws",
				"security":    "tls",
				"sni":         "localhost",
				"insecure":    "true",
				"fingerprint": "chrome",
			},
		}
	}

	// 1. Bad credentials MUST result in zero target hits.
	// If NO_PROXY had caused a bypass to direct loopback, targetHits would be > 0.
	badServer := buildServer("node-bad-proxy-env", invalidUUID)
	resBad := ProbeCandidateIsolated(context.Background(), "grp-1", badServer, tsTarget.URL, 3)

	if resBad.Successful {
		t.Fatalf("expected bad credentials probe to fail, got success: %+v", resBad)
	}
	if resBad.Successes != 0 {
		t.Errorf("expected 0 successes for bad credentials, got %d", resBad.Successes)
	}
	if hits := targetHits.Load(); hits != 0 {
		t.Fatalf("LEAKAGE DETECTED: target hit count is %d (expected 0); probe bypassed the bad tunnel!", hits)
	}

	// 2. Good credentials flow through the candidate tunnel despite NO_PROXY/HTTPS_PROXY env.
	goodServer := buildServer("node-good-proxy-env", validUUID)
	resGood := ProbeCandidateIsolated(context.Background(), "grp-1", goodServer, tsTarget.URL, 3)

	if !resGood.Successful {
		t.Fatalf("expected good credentials probe to succeed, got: %+v", resGood)
	}
	if resGood.Successes != 3 {
		t.Errorf("expected 3 successes for good credentials, got %d", resGood.Successes)
	}
	if targetHits.Load() == 0 {
		t.Errorf("expected target hits > 0 with good tunnel, got 0")
	}
}

func TestProbeCandidateIsolated_SlowEndpoint_ExecutionBounded(t *testing.T) {
	bin := resolveTestSingBox(t)
	if bin == "" {
		t.Skip("sing-box binary not found")
	}

	validUUID := "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
	srvPort, cleanupServer := startRealSingBoxVLESSServer(t, bin, validUUID)
	defer cleanupServer()

	// Slow server sleeping longer than the 2s per-sample timeout
	tsSlow := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(3 * time.Second)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer tsSlow.Close()

	pool := x509.NewCertPool()
	pool.AddCert(tsSlow.Certificate())

	tlsConfig := &tls.Config{
		RootCAs:            pool,
		InsecureSkipVerify: false,
		MinVersion:         tls.VersionTLS12,
	}

	cleanup := SetInjectedCandidateProbeTargetForTest(tsSlow.URL, tlsConfig)
	defer cleanup()

	server := proto.Server{
		ID:       "node-slow",
		Name:     "Slow Node",
		Protocol: proto.ProtoVLESS,
		Address:  "127.0.0.1",
		Port:     srvPort,
		Raw: map[string]any{
			"uuid":        validUUID,
			"network":     "ws",
			"path":        "/ws",
			"security":    "tls",
			"sni":         "localhost",
			"insecure":    "true",
			"fingerprint": "chrome",
		},
	}

	// 3 samples each timing out at 2s; bound overall probe to ensure clean termination
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	start := time.Now()
	res := ProbeCandidateIsolated(ctx, "grp-1", server, tsSlow.URL, 3)
	elapsed := time.Since(start)

	if res.Successful {
		t.Fatalf("expected slow endpoint probe to fail, got success: %+v", res)
	}
	if res.Successes != 0 {
		t.Errorf("expected 0 successes on slow endpoint, got %d", res.Successes)
	}
	// Ensure probe did not hang indefinitely
	if elapsed > 12*time.Second {
		t.Errorf("probe took too long (%v), exceeded expected bound", elapsed)
	}
}

func TestProbeCandidateIsolated_GlobalConcurrencyBounding(t *testing.T) {
	// Saturate global candidate semaphore
	for i := 0; i < MaxConcurrentCandidateProbes; i++ {
		candidateProbeSem <- struct{}{}
	}
	defer func() {
		for i := 0; i < MaxConcurrentCandidateProbes; i++ {
			<-candidateProbeSem
		}
	}()

	server := proto.Server{
		ID:       "node-sem-overflow",
		Name:     "Overflow Node",
		Protocol: proto.ProtoVLESS,
		Address:  "127.0.0.1",
		Port:     443,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	res := ProbeCandidateIsolated(ctx, "grp-1", server, DefaultCandidateProbeURL, 3)
	if res.ProbeKind != "concurrency_timeout" {
		t.Errorf("expected probeKind 'concurrency_timeout' when semaphore full, got %q", res.ProbeKind)
	}
	if res.Successful {
		t.Errorf("expected failed result when semaphore full, got success: %+v", res)
	}
}
