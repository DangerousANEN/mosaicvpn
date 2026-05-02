package state

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/DangerousANEN/mosaicvpn/internal/logx"
	"github.com/DangerousANEN/mosaicvpn/internal/proto"
	"github.com/DangerousANEN/mosaicvpn/internal/store"
)

// URLTestResult is what /v1/servers/{id}/url-test returns. RTT is the
// time spent waiting for the test URL to respond, in milliseconds.
// Status is the HTTP status code of the test endpoint (204 = success,
// 200 = success for the alt endpoint). Error is non-empty when the
// probe failed; RTT and Status may still be set partially when the
// SOCKS dial succeeds but the HTTP response is unexpected.
type URLTestResult struct {
	RTTMS  int    `json:"rtt_ms"`
	Status int    `json:"status"`
	Error  string `json:"error,omitempty"`
}

// urlTestMu serialises URL tests so we don't fan out N copies of
// sing-box on a slow host. Each call holds the mutex for the duration
// of the spin-up + probe + tear-down — typically <5 s.
var urlTestMu sync.Mutex

// DefaultURLTestEndpoint is the historic gstatic-204 captive-portal
// probe — used when Prefs.URLTestEndpoint is empty.
const DefaultURLTestEndpoint = "https://www.gstatic.com/generate_204"

// URLTestServer launches an ephemeral sing-box bound to a free
// loopback SOCKS port using the given server's outbound, then
// performs HTTP GET against `target` through it.  Any 2xx/3xx
// response is treated as success — gstatic returns 204, www.google.com
// returns 200, etc., and we don't want to surface a "fail" just because
// the user picked a non-captive-portal endpoint.
//
// The whole exercise takes ~2-4 s end-to-end. The function never
// touches the user's primary connection state; it spins its own
// sing-box subprocess, captures the result, and kills it.
func URLTestServer(ctx context.Context, binary, dataDir, target string, prefs store.Prefs, server proto.Server, timeout time.Duration) URLTestResult {
	urlTestMu.Lock()
	defer urlTestMu.Unlock()

	if timeout <= 0 {
		timeout = 12 * time.Second
	}
	bin := binary
	if bin == "" {
		bin = LocateSingBox()
	}
	if bin == "" {
		return URLTestResult{Error: "sing-box binary not found"}
	}
	if _, err := os.Stat(bin); err != nil {
		return URLTestResult{Error: fmt.Sprintf("sing-box binary %q: %v", bin, err)}
	}
	socksPort := pickPort(0)
	if socksPort == 0 {
		return URLTestResult{Error: "could not bind a free loopback port"}
	}
	// We deliberately strip clash-api / TUN inbound here — URL test is
	// a thin proxy probe and must not touch the OS routing table.
	// rc42 — pass anti-DPI overrides from prefs so the Verify probe
	// uses the same uTLS / fragment / mux settings the user picked
	// for live connections.  Force proxy mode so we don't try to
	// open a TUN inbound from an ephemeral helper.
	utPrefs := prefs
	utPrefs.TunnelMode = "proxy"
	// rc48 — Verify is an isolated probe; pass nil for user rules so
	// the only bypass entries in the ephemeral config are the
	// hard-coded system geo hosts. User-defined splits don't apply
	// to the test path: we want to know whether *the proxy itself*
	// can reach the target, not whether the user's bypass list
	// would have skipped it.
	cfg, err := BuildSingBoxConfig(server, utPrefs, nil, socksPort, pickPort(0), 0)
	if err != nil {
		return URLTestResult{Error: "build config: " + err.Error()}
	}
	if dataDir == "" {
		dataDir = os.TempDir()
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return URLTestResult{Error: "ensure data dir: " + err.Error()}
	}
	cfgPath := filepath.Join(dataDir, fmt.Sprintf("singbox-urltest-%d.json", socksPort))
	if err := os.WriteFile(cfgPath, cfg, 0o600); err != nil {
		return URLTestResult{Error: "write config: " + err.Error()}
	}
	defer os.Remove(cfgPath)

	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, bin, "run", "-c", cfgPath, "-D", dataDir)
	cmd.Dir = dataDir
	logPath := filepath.Join(dataDir, fmt.Sprintf("singbox-urltest-%d.log", socksPort))
	logFile, _ := os.Create(logPath)
	// rc40 — keep the log file around so callers can diagnose
	// "unexpected EOF" without spawning a new sing-box.  We close
	// the handle (so writes flush) but do not delete the file.
	// Each url-test reuses a unique port-keyed name, so old logs
	// won't accumulate beyond what's reasonable for one session.
	if logFile != nil {
		cmd.Stdout = logFile
		cmd.Stderr = logFile
		defer func() {
			_ = logFile.Close()
		}()
	}
	if err := cmd.Start(); err != nil {
		return URLTestResult{Error: "spawn sing-box: " + err.Error()}
	}
	defer func() {
		_ = killProcess(cmd)
		_, _ = cmd.Process.Wait()
	}()

	// rc48 — flushLog forces buffered sing-box stderr to disk before
	// we slurp the tail. Without this, Windows hands us back an empty
	// file because the OS cache hasn't been flushed yet, so the user
	// sees the bare "unexpected EOF" the rc40 fix was supposed to
	// dress up with sing-box context.
	flushLog := func() {
		if logFile != nil {
			_ = logFile.Sync()
		}
	}

	if err := waitForListen(cctx, "127.0.0.1", socksPort, 5*time.Second); err != nil {
		flushLog()
		return URLTestResult{Error: "sing-box did not start: " + readURLTestTail(logPath, 600)}
	}

	// Use 204 endpoint — Google's well-known captive-portal probe; if
	// it returns anything other than 204 we're behind a captive
	// portal or the proxy is rewriting traffic, and either way the
	// server is not delivering clean internet.
	socksURL := fmt.Sprintf("socks5h://127.0.0.1:%d", socksPort)
	proxyURL, _ := url.Parse(socksURL)
	client := &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			Proxy: http.ProxyURL(proxyURL),
			DialContext: (&net.Dialer{
				Timeout: 4 * time.Second,
			}).DialContext,
			TLSHandshakeTimeout: 6 * time.Second,
		},
	}
	if target == "" {
		target = DefaultURLTestEndpoint
	}
	t0 := time.Now()
	req, err := http.NewRequestWithContext(cctx, http.MethodGet, target, nil)
	if err != nil {
		return URLTestResult{Error: "build request: " + err.Error()}
	}
	req.Header.Set("User-Agent", "mosaicvpn/0.1 (url-test)")
	resp, err := client.Do(req)
	if err != nil {
		// Distinguish dial failure (proxy reachable but upstream broken)
		// from the entire proxy being unreachable. We surface the raw
		// error message either way; the UI prepends a label.
		base := classifyURLTestErr(err)
		// rc40 — for opaque "unexpected EOF" / connection-reset
		// failures, append the last ~600 bytes of the sing-box
		// log so the user sees what really happened (TLS abort,
		// server reset, no auth handshake, etc.) instead of a
		// blank "Get …: unexpected EOF".  rc48: explicit Sync()
		// before the read, plus we surface the log path on disk
		// so the user can grab the full text manually if the
		// 600-byte tail still doesn't show the cause.
		flushLog()
		if tail := readURLTestTail(logPath, 600); tail != "" {
			logx.Debug("url-test failed", "server", server.ID,
				"err", base, "singbox_tail", tail)
			base = base + " | singbox: " + condense(tail)
		} else {
			logx.Debug("url-test failed (no singbox log)", "server", server.ID, "err", base)
			base = base + " | log: " + logPath
		}
		return URLTestResult{Error: base, RTTMS: int(time.Since(t0).Milliseconds())}
	}
	defer resp.Body.Close()
	rtt := int(time.Since(t0).Milliseconds())
	if rtt < 1 {
		rtt = 1
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	// Any 2xx/3xx is positive proof that we reached the target —
	// gstatic returns 204, www.google.com returns 200, cloudflare's
	// trace returns 200, and a custom user URL might redirect.  We
	// don't want to surface a "fail" for the user-picked URL just
	// because it doesn't speak the gstatic captive-portal protocol.
	if resp.StatusCode >= 400 {
		return URLTestResult{
			RTTMS:  rtt,
			Status: resp.StatusCode,
			Error:  fmt.Sprintf("unexpected status %d", resp.StatusCode),
		}
	}
	logx.Debug("url-test ok", "server", server.ID, "rtt_ms", rtt, "status", resp.StatusCode)
	return URLTestResult{RTTMS: rtt, Status: resp.StatusCode}
}

func classifyURLTestErr(err error) string {
	if err == nil {
		return ""
	}
	msg := err.Error()
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout: " + msg
	}
	return msg
}

func readURLTestTail(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	if len(data) > n {
		data = data[len(data)-n:]
	}
	return string(data)
}

// condense flattens a multi-line sing-box log tail into a single line
// by joining on " | " and dropping common-prefix timestamps so the
// resulting "verify failed | singbox: …" string fits in the UI's
// error column.  Returns at most ~280 chars of payload.
func condense(s string) string {
	var b strings.Builder
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimRight(line, " \t\r")
		// Drop "+0000 INFO " etc. structured prefixes; keep payload.
		if i := strings.Index(line, "INFO "); i >= 0 {
			line = line[i+len("INFO "):]
		} else if i := strings.Index(line, "ERROR "); i >= 0 {
			line = line[i+len("ERROR "):]
		}
		if line == "" {
			continue
		}
		if b.Len() > 0 {
			b.WriteString(" | ")
		}
		b.WriteString(line)
		if b.Len() > 280 {
			out := b.String()
			if len(out) > 280 {
				out = out[:280]
			}
			return out + "…"
		}
	}
	return b.String()
}

func killProcess(cmd *exec.Cmd) error {
	if cmd == nil || cmd.Process == nil {
		return nil
	}
	if runtime.GOOS == "windows" {
		// Kill() on Windows already terminates the process; sing-box
		// has no graceful shutdown signal we can deliver from Go on
		// this OS anyway.
		return cmd.Process.Kill()
	}
	return cmd.Process.Kill()
}


