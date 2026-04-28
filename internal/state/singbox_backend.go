package state

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/logx"
	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

// SingBoxBackend drives a bundled sing-box executable as a child
// process. It writes a config file derived from the chosen server,
// launches sing-box, waits for the loopback SOCKS port to come up, and
// kills the process on Stop.
//
// While sing-box is running the backend also runs two pollers:
//   - clashAPIPoll: hits the embedded clash API's /connections every
//     second to keep BytesIn/BytesOut fresh for the Atlas screen.
//   - latencyPoll: re-probes the connected server's TCP endpoint
//     every 5 s and stores the round-trip in LatencyMS so the user
//     sees a live latency reading instead of a frozen 0.
//
// Both pollers are best-effort — if the clash API isn't ready or the
// remote endpoint is unreachable the previous values are kept and a
// debug log is emitted.
type SingBoxBackend struct {
	mu      sync.Mutex
	binary  string // resolved path to sing-box.exe
	dataDir string

	cmd       *exec.Cmd
	cancel    context.CancelFunc
	doneCh    chan struct{}
	socks     string
	http      string
	clashAPI  string // "127.0.0.1:<port>", empty if disabled
	bytesIn   atomic.Uint64
	bytesOut  atomic.Uint64
	latencyMS atomic.Int32
}

// NewSingBoxBackend constructs a backend rooted at dataDir (where the
// generated config and stdout/stderr logs live). Pass an empty binary
// to auto-resolve via LocateSingBox; pass an explicit path (e.g. from a
// CLI flag or env var) to override.
func NewSingBoxBackend(binary, dataDir string) *SingBoxBackend {
	return &SingBoxBackend{binary: binary, dataDir: dataDir}
}

// LocateSingBox returns the first sing-box executable found next to
// the current binary, then on PATH. Returns "" if nothing is found.
func LocateSingBox() string {
	exeName := "sing-box"
	if runtime.GOOS == "windows" {
		exeName = "sing-box.exe"
	}
	if self, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(self), exeName)
		if fi, err := os.Stat(candidate); err == nil && !fi.IsDir() {
			return candidate
		}
	}
	if p, err := exec.LookPath(exeName); err == nil {
		return p
	}
	return ""
}

// Name implements Backend.
func (b *SingBoxBackend) Name() string { return "sing-box" }

// Proxies implements ProxyListener.
func (b *SingBoxBackend) Proxies() (string, string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.socks, b.http
}

// Stats implements Backend.
func (b *SingBoxBackend) Stats() (uint64, uint64, int) {
	return b.bytesIn.Load(), b.bytesOut.Load(), int(b.latencyMS.Load())
}

// Start implements Backend.
func (b *SingBoxBackend) Start(ctx context.Context, server proto.Server, _ store.Prefs, _ []proto.Rule) error {
	b.mu.Lock()
	if b.cmd != nil {
		b.mu.Unlock()
		return errors.New("sing-box already running")
	}
	bin := b.binary
	if bin == "" {
		bin = LocateSingBox()
	}
	if bin == "" {
		b.mu.Unlock()
		return errors.New("sing-box binary not found next to mosaicd or on PATH")
	}
	if _, err := os.Stat(bin); err != nil {
		b.mu.Unlock()
		return fmt.Errorf("sing-box binary %q: %w", bin, err)
	}

	// Pick free SOCKS / HTTP / clash-api loopback ports. Defaults are
	// 2080 / 2081 / 9090 (the sing-box documented default for clash
	// API) but each falls back to an ephemeral port if the default is
	// already taken on the host.
	socksPort := pickPort(2080)
	httpPort := pickPort(2081)
	clashPort := pickPort(9090)
	if socksPort == 0 || httpPort == 0 {
		b.mu.Unlock()
		return errors.New("could not bind a free loopback port for sing-box proxies")
	}

	cfg, err := BuildSingBoxConfig(server, socksPort, httpPort, clashPort)
	if err != nil {
		b.mu.Unlock()
		return fmt.Errorf("build sing-box config: %w", err)
	}
	cfgPath := filepath.Join(b.dataDir, "singbox-current.json")
	if err := os.WriteFile(cfgPath, cfg, 0o600); err != nil {
		b.mu.Unlock()
		return fmt.Errorf("write sing-box config: %w", err)
	}

	cctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(cctx, bin, "run", "-c", cfgPath, "-D", b.dataDir)
	cmd.Dir = b.dataDir

	outLog, _ := os.Create(filepath.Join(b.dataDir, "singbox.out.log"))
	errLog, _ := os.Create(filepath.Join(b.dataDir, "singbox.err.log"))
	cmd.Stdout = outLog
	cmd.Stderr = errLog

	if err := cmd.Start(); err != nil {
		cancel()
		if outLog != nil {
			_ = outLog.Close()
		}
		if errLog != nil {
			_ = errLog.Close()
		}
		b.mu.Unlock()
		return fmt.Errorf("start sing-box: %w", err)
	}

	b.cmd = cmd
	b.cancel = cancel
	b.doneCh = make(chan struct{})
	b.socks = fmt.Sprintf("127.0.0.1:%d", socksPort)
	b.http = fmt.Sprintf("127.0.0.1:%d", httpPort)
	if clashPort > 0 {
		b.clashAPI = fmt.Sprintf("127.0.0.1:%d", clashPort)
	} else {
		b.clashAPI = ""
	}
	b.bytesIn.Store(0)
	b.bytesOut.Store(0)
	b.latencyMS.Store(0)
	doneCh := b.doneCh
	clashEndpoint := b.clashAPI
	b.mu.Unlock()

	go func() {
		err := cmd.Wait()
		if outLog != nil {
			_ = outLog.Close()
		}
		if errLog != nil {
			_ = errLog.Close()
		}
		if err != nil && cctx.Err() == nil {
			logx.Warn("sing-box exited", "err", err)
		}
		close(doneCh)
	}()

	// Wait for SOCKS to be listening before we report success. Use the
	// caller's ctx so the API call cancels cleanly if the user gives
	// up. Probe for up to 6 s — sing-box on Windows is normally ready
	// in < 500 ms.
	if err := waitForListen(ctx, "127.0.0.1", socksPort, 6*time.Second); err != nil {
		// Best-effort cleanup; surface the underlying reason.
		_ = b.Stop(context.Background())
		errReason := readTail(filepath.Join(b.dataDir, "singbox.err.log"), 600)
		if errReason != "" {
			return fmt.Errorf("sing-box did not start: %s", errReason)
		}
		return fmt.Errorf("sing-box did not start: %w", err)
	}

	// Spin up the metric pollers. Both run for the lifetime of cctx;
	// Stop() cancels cctx which kicks both goroutines out of their
	// select.
	go b.clashAPIPoll(cctx, clashEndpoint)
	go b.latencyPoll(cctx, server)

	return nil
}

// clashAPIPoll hits sing-box's embedded clash API and refreshes
// bytesIn/bytesOut once a second. The /connections endpoint returns
// monotonic totals (downloadTotal / uploadTotal) so we just store them
// directly. Errors are logged at debug level only — a clash poll
// failure must not bring down the connection.
func (b *SingBoxBackend) clashAPIPoll(ctx context.Context, endpoint string) {
	if endpoint == "" {
		return
	}
	client := &http.Client{Timeout: 800 * time.Millisecond}
	url := fmt.Sprintf("http://%s/connections", endpoint)
	// First few attempts may race the daemon's bootstrap. Back off in
	// 200 ms steps until either ctx fires or we get a 200.
	warm := time.NewTicker(200 * time.Millisecond)
	defer warm.Stop()
	warmDeadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(warmDeadline) {
		if ctx.Err() != nil {
			return
		}
		if b.fetchClashTotals(ctx, client, url) {
			break
		}
		select {
		case <-warm.C:
		case <-ctx.Done():
			return
		}
	}
	t := time.NewTicker(1 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			b.fetchClashTotals(ctx, client, url)
		}
	}
}

func (b *SingBoxBackend) fetchClashTotals(ctx context.Context, client *http.Client, url string) bool {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return false
	}
	resp, err := client.Do(req)
	if err != nil {
		logx.Debug("clash-api poll failed", "err", err)
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, resp.Body)
		return false
	}
	var payload struct {
		DownloadTotal uint64 `json:"downloadTotal"`
		UploadTotal   uint64 `json:"uploadTotal"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		logx.Debug("clash-api decode failed", "err", err)
		return false
	}
	b.bytesIn.Store(payload.DownloadTotal)
	b.bytesOut.Store(payload.UploadTotal)
	return true
}

// latencyPoll re-probes the connected server's TCP endpoint every 5 s
// and stores the round-trip in latencyMS. Uses ResolvedIP if available
// (set by api.handleTestServer / handleTestAll) so the dial bypasses
// any system-DNS hijack the way rc13 fixed it for Test all.
func (b *SingBoxBackend) latencyPoll(ctx context.Context, server proto.Server) {
	if server.Port <= 0 {
		return
	}
	host := server.ResolvedIP
	if host == "" {
		host = server.Address
	}
	if host == "" {
		return
	}
	target := net.JoinHostPort(host, strconv.Itoa(server.Port))
	probe := func() {
		dialer := net.Dialer{Timeout: 3 * time.Second}
		cctx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		t0 := time.Now()
		conn, err := dialer.DialContext(cctx, "tcp", target)
		if err != nil {
			logx.Debug("active latency probe failed", "target", target, "err", err)
			return
		}
		elapsed := time.Since(t0)
		_ = conn.Close()
		us := elapsed.Microseconds()
		ms := int32((us + 500) / 1000)
		if ms < 1 {
			ms = 1
		}
		b.latencyMS.Store(ms)
	}
	// Probe once immediately so the UI doesn't sit on 0 for 5 s.
	probe()
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			probe()
		}
	}
}

// Stop implements Backend.
func (b *SingBoxBackend) Stop(_ context.Context) error {
	b.mu.Lock()
	cancel := b.cancel
	doneCh := b.doneCh
	b.cmd = nil
	b.cancel = nil
	b.doneCh = nil
	b.socks = ""
	b.http = ""
	b.clashAPI = ""
	b.bytesIn.Store(0)
	b.bytesOut.Store(0)
	b.latencyMS.Store(0)
	b.mu.Unlock()
	if cancel == nil {
		return nil
	}
	cancel()
	if doneCh != nil {
		select {
		case <-doneCh:
		case <-time.After(5 * time.Second):
			// Ignore; process will be reaped by the OS.
		}
	}
	return nil
}

// pickPort returns preferred if it's free, otherwise an ephemeral
// loopback port. Returns 0 only if even the ephemeral allocation fails.
func pickPort(preferred int) int {
	if l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", preferred)); err == nil {
		_ = l.Close()
		return preferred
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0
	}
	defer l.Close()
	_, portStr, _ := net.SplitHostPort(l.Addr().String())
	port, _ := strconv.Atoi(portStr)
	return port
}

// waitForListen polls the given loopback host:port until something is
// accepting connections or the deadline elapses.
func waitForListen(ctx context.Context, host string, port int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), 250*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for %s:%d", host, port)
		}
		time.Sleep(150 * time.Millisecond)
	}
}

// readTail returns the trailing n bytes of path, decoded as UTF-8.
// Best-effort: returns "" on any read error.
func readTail(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	if len(data) > n {
		data = data[len(data)-n:]
	}
	return string(data)
}

// BuildSingBoxConfig translates a Mosaic Server into a sing-box config
// document with a SOCKS and HTTP inbound on loopback and a single
// proxy outbound. When clashPort > 0 the config also enables sing-box's
// embedded clash API on "127.0.0.1:<clashPort>" so the daemon can poll
// /connections for live byte counters. Exposed for tests.
func BuildSingBoxConfig(server proto.Server, socksPort, httpPort, clashPort int) ([]byte, error) {
	out, err := outboundFor(server)
	if err != nil {
		return nil, err
	}
	cfg := map[string]any{
		"log": map[string]any{
			"level":     "warn",
			"timestamp": true,
		},
		"inbounds": []any{
			map[string]any{
				"type":        "socks",
				"tag":         "socks-in",
				"listen":      "127.0.0.1",
				"listen_port": socksPort,
				"sniff":       true,
			},
			map[string]any{
				"type":        "http",
				"tag":         "http-in",
				"listen":      "127.0.0.1",
				"listen_port": httpPort,
				"sniff":       true,
			},
		},
		"outbounds": []any{
			out,
			map[string]any{"type": "direct", "tag": "direct"},
			map[string]any{"type": "block", "tag": "block"},
			map[string]any{"type": "dns", "tag": "dns-out"},
		},
		"route": map[string]any{
			"final": "proxy",
			"rules": []any{
				map[string]any{"protocol": "dns", "outbound": "dns-out"},
			},
		},
	}
	if clashPort > 0 {
		cfg["experimental"] = map[string]any{
			"clash_api": map[string]any{
				"external_controller": fmt.Sprintf("127.0.0.1:%d", clashPort),
				// No secret — only loopback can hit it; mosaicd is the
				// only consumer.
			},
		}
	}
	return json.MarshalIndent(cfg, "", "  ")
}

// outboundFor builds the sing-box outbound block matching the server's
// protocol. Unknown / partial inputs return a descriptive error so the
// user sees something more helpful than "json: cannot unmarshal …".
func outboundFor(s proto.Server) (map[string]any, error) {
	rs := func(k string) string {
		if s.Raw == nil {
			return ""
		}
		v, ok := s.Raw[k]
		if !ok || v == nil {
			return ""
		}
		switch t := v.(type) {
		case string:
			return t
		case json.Number:
			return t.String()
		case float64:
			return strconv.FormatFloat(t, 'f', -1, 64)
		}
		return fmt.Sprintf("%v", v)
	}
	switch s.Protocol {
	case proto.ProtoVLESS:
		out := map[string]any{
			"type":        "vless",
			"tag":         "proxy",
			"server":      s.Address,
			"server_port": s.Port,
			"uuid":        rs("uuid"),
		}
		if flow := rs("flow"); flow != "" {
			out["flow"] = flow
		}
		security := rs("security")
		network := rs("network")
		tlsBlock := map[string]any{}
		if security == "tls" || security == "reality" || rs("sni") != "" {
			tlsBlock["enabled"] = true
			if sni := rs("sni"); sni != "" {
				tlsBlock["server_name"] = sni
			}
			if fp := rs("fingerprint"); fp != "" {
				tlsBlock["utls"] = map[string]any{
					"enabled":     true,
					"fingerprint": fp,
				}
			}
			if security == "reality" {
				tlsBlock["reality"] = map[string]any{
					"enabled":    true,
					"public_key": rs("public_key"),
					"short_id":   rs("short_id"),
				}
			}
		}
		if len(tlsBlock) > 0 {
			out["tls"] = tlsBlock
		}
		switch network {
		case "ws":
			ws := map[string]any{}
			if path := rs("path"); path != "" {
				ws["path"] = path
			}
			if host := rs("host"); host != "" {
				ws["headers"] = map[string]any{"Host": host}
			}
			out["transport"] = mergeMap(map[string]any{"type": "ws"}, ws)
		case "grpc":
			out["transport"] = map[string]any{
				"type":         "grpc",
				"service_name": rs("path"),
			}
		case "xhttp", "http":
			t := map[string]any{"type": "http"}
			if path := rs("path"); path != "" {
				t["path"] = path
			}
			if host := rs("host"); host != "" {
				t["host"] = []any{host}
			}
			out["transport"] = t
		}
		return out, nil
	case proto.ProtoHysteria2:
		out := map[string]any{
			"type":        "hysteria2",
			"tag":         "proxy",
			"server":      s.Address,
			"server_port": s.Port,
			"password":    rs("password"),
		}
		tls := map[string]any{"enabled": true}
		if sni := rs("sni"); sni != "" {
			tls["server_name"] = sni
		}
		if rs("insecure") == "true" || rs("allow_insecure") == "1" || rs("skip-cert-verify") == "true" {
			tls["insecure"] = true
		}
		out["tls"] = tls
		if obfs := rs("obfs"); obfs != "" {
			out["obfs"] = map[string]any{
				"type":     obfs,
				"password": rs("obfs-password"),
			}
		}
		return out, nil
	case proto.ProtoShadowsocks:
		out := map[string]any{
			"type":        "shadowsocks",
			"tag":         "proxy",
			"server":      s.Address,
			"server_port": s.Port,
			"method":      rs("method"),
			"password":    rs("password"),
		}
		return out, nil
	case proto.ProtoNaive:
		// sing-box doesn't ship a native naive client; we proxy via a
		// chained http-tunnel. The real fix is to bundle naïve too,
		// but that's out of scope for rc10.
		return nil, errors.New("naive proxy not yet supported by bundled sing-box; pick another station")
	case proto.ProtoAmneziaWG:
		return nil, errors.New("amneziawg not yet supported; pick another station")
	}
	return nil, fmt.Errorf("unsupported protocol %q", s.Protocol)
}

func mergeMap(a, b map[string]any) map[string]any {
	for k, v := range b {
		a[k] = v
	}
	return a
}
