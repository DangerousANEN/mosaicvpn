package state

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
	"time"
)

// TestVerifyCatchesRealSingBoxMuxBlackHole is the regression that matters:
// it drives the ACTUAL sing-box binary with the ACTUAL multiplex config that
// fooled us, and asserts the truth-check refuses it.
//
// Why this exists: `sing-box check` validates that config, the core starts
// without error, and the SOCKS port opens and completes handshakes — every
// signal we used to trust says "connected". Only real traffic reveals that
// sing-box dials sp.mux.sing-box.arpa, which an Xray peer does not speak, so
// every stream is silently dropped.
//
// The test is skipped when the binary or the network is unavailable so CI on
// a bare runner stays green; it is exercised on the dev machine and any runner
// that has the core.
func TestVerifyCatchesRealSingBoxMuxBlackHole(t *testing.T) {
	bin := singBoxBinaryForTest()
	if bin == "" {
		t.Skip("sing-box binary not available on this machine")
	}
	link := os.Getenv("MOSAIC_TEST_VLESS_WS_LINK")
	if link == "" {
		t.Skip("MOSAIC_TEST_VLESS_WS_LINK not set; skipping live-core regression")
	}

	socksPort := freePortForTest(t)

	// Same outbound twice: once plain (must verify), once with multiplex
	// against the Xray peer (must be rejected).
	for _, tc := range []struct {
		name       string
		mux        bool
		wantVerify bool
	}{
		{name: "plain", mux: false, wantVerify: true},
		{name: "multiplex_h2mux", mux: true, wantVerify: false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfgPath := writeLiveProbeConfig(t, link, socksPort, tc.mux)

			// Sanity: the config is schema-valid either way. This is the whole
			// point — validation cannot distinguish these two.
			if out, err := exec.Command(bin, "check", "-c", cfgPath).CombinedOutput(); err != nil {
				t.Fatalf("sing-box check unexpectedly rejected config: %v\n%s", err, out)
			}

			ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
			defer cancel()

			cmd := exec.CommandContext(ctx, bin, "run", "-c", cfgPath)
			if err := cmd.Start(); err != nil {
				t.Fatalf("start sing-box: %v", err)
			}
			defer func() {
				_ = cmd.Process.Kill()
				_, _ = cmd.Process.Wait()
			}()

			socks := fmt.Sprintf("127.0.0.1:%d", socksPort)
			waitForPortForTest(t, socks, 10*time.Second)

			res := verifyTunnel(ctx, socks, VerifyPolicy{
				Attempts:          2,
				PerAttemptTimeout: 8 * time.Second,
				Backoff:           500 * time.Millisecond,
			})

			if res.OK != tc.wantVerify {
				t.Fatalf("verify OK=%v, want %v (target=%s, attempts=%d, err=%v)",
					res.OK, tc.wantVerify, res.Target, res.Attempts, res.Err)
			}
		})
	}
}

func singBoxBinaryForTest() string {
	candidates := []string{
		os.Getenv("MOSAIC_SINGBOX_BIN"),
	}
	if runtime.GOOS == "windows" {
		if la := os.Getenv("LOCALAPPDATA"); la != "" {
			candidates = append(candidates,
				filepath.Join(la, "Programs", "MosaicVPN", "sing-box.exe"))
		}
	} else {
		candidates = append(candidates, "/usr/local/bin/sing-box", "/usr/bin/sing-box")
	}
	for _, c := range candidates {
		if c == "" {
			continue
		}
		if fi, err := os.Stat(c); err == nil && !fi.IsDir() {
			return c
		}
	}
	if p, err := exec.LookPath("sing-box"); err == nil {
		return p
	}
	return ""
}

func freePortForTest(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve port: %v", err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

func waitForPortForTest(t *testing.T, addr string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("tcp", addr, 500*time.Millisecond)
		if err == nil {
			_ = c.Close()
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatalf("port %s never opened", addr)
}

// writeLiveProbeConfig renders a minimal sing-box config from a vless:// ws
// share link, optionally enabling multiplex.
func writeLiveProbeConfig(t *testing.T, shareLink string, socksPort int, mux bool) string {
	t.Helper()
	ob, err := outboundFromVlessWSLink(shareLink)
	if err != nil {
		t.Fatalf("parse share link: %v", err)
	}
	if mux {
		ob["multiplex"] = map[string]any{
			"enabled":         true,
			"protocol":        "h2mux",
			"max_connections": 4,
			"padding":         true,
		}
	}
	cfg := map[string]any{
		"log": map[string]any{"level": "error"},
		"inbounds": []any{map[string]any{
			"type": "mixed", "tag": "in",
			"listen": "127.0.0.1", "listen_port": socksPort,
		}},
		"outbounds": []any{ob},
	}
	blob, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		t.Fatalf("marshal config: %v", err)
	}
	path := filepath.Join(t.TempDir(), "probe.json")
	if err := os.WriteFile(path, blob, 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

// outboundFromVlessWSLink converts a vless:// share link with ws transport
// into a sing-box outbound. Kept local to the test so production parsing code
// is not bent to fit a test's needs.
func outboundFromVlessWSLink(link string) (map[string]any, error) {
	u, err := url.Parse(link)
	if err != nil {
		return nil, err
	}
	if u.Scheme != "vless" {
		return nil, fmt.Errorf("unsupported scheme %q", u.Scheme)
	}
	if u.User == nil || u.User.Username() == "" {
		return nil, errors.New("link carries no uuid")
	}
	port := 443
	if p := u.Port(); p != "" {
		if n, convErr := strconv.Atoi(p); convErr == nil {
			port = n
		}
	}
	q := u.Query()
	sni := q.Get("sni")
	if sni == "" {
		sni = q.Get("host")
	}
	fp := q.Get("fp")
	if fp == "" {
		fp = "chrome"
	}
	wsPath := q.Get("path")
	if wsPath == "" {
		wsPath = "/"
	}

	return map[string]any{
		"type":        "vless",
		"tag":         "out",
		"server":      u.Hostname(),
		"server_port": port,
		"uuid":        u.User.Username(),
		"tls": map[string]any{
			"enabled":     true,
			"server_name": sni,
			"utls":        map[string]any{"enabled": true, "fingerprint": fp},
		},
		"transport": map[string]any{
			"type":    "ws",
			"path":    wsPath,
			"headers": map[string]any{"Host": q.Get("host")},
		},
	}, nil
}
