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

// URLTestServer launches an ephemeral sing-box bound to a free
// loopback SOCKS port using the given server's outbound, then
// performs HTTP GET https://www.gstatic.com/generate_204 through it.
// A 204 response is a positive proof that the proxy actually carries
// real traffic — much stronger than a TCP probe of the server endpoint
// (which only proves something is listening on the port).
//
// The whole exercise takes ~2-4 s end-to-end. The function never
// touches the user's primary connection state; it spins its own
// sing-box subprocess, captures the result, and kills it.
func URLTestServer(ctx context.Context, binary, dataDir string, server proto.Server, timeout time.Duration) URLTestResult {
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
	cfg, err := BuildSingBoxConfig(server, store.Prefs{TunnelMode: "proxy"}, socksPort, pickPort(0), 0)
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
	if logFile != nil {
		cmd.Stdout = logFile
		cmd.Stderr = logFile
		defer func() {
			_ = logFile.Close()
			_ = os.Remove(logPath)
		}()
	}
	if err := cmd.Start(); err != nil {
		return URLTestResult{Error: "spawn sing-box: " + err.Error()}
	}
	defer func() {
		_ = killProcess(cmd)
		_, _ = cmd.Process.Wait()
	}()

	if err := waitForListen(cctx, "127.0.0.1", socksPort, 5*time.Second); err != nil {
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
	target := "https://www.gstatic.com/generate_204"
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
		return URLTestResult{Error: classifyURLTestErr(err), RTTMS: int(time.Since(t0).Milliseconds())}
	}
	defer resp.Body.Close()
	rtt := int(time.Since(t0).Milliseconds())
	if rtt < 1 {
		rtt = 1
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusOK {
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


