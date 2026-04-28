package state

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
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
// kills the process on Stop. Bytes counters are not yet wired up — the
// manager will report zeros until the clash-api glue lands.
type SingBoxBackend struct {
	mu      sync.Mutex
	binary  string // resolved path to sing-box.exe
	dataDir string

	cmd       *exec.Cmd
	cancel    context.CancelFunc
	doneCh    chan struct{}
	socks     string
	http      string
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

	// Pick free SOCKS / HTTP loopback ports. Default to 2080/2081 but
	// fall back to ephemeral if those are taken.
	socksPort := pickPort(2080)
	httpPort := pickPort(2081)
	if socksPort == 0 || httpPort == 0 {
		b.mu.Unlock()
		return errors.New("could not bind a free loopback port for sing-box proxies")
	}

	cfg, err := BuildSingBoxConfig(server, socksPort, httpPort)
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
	b.bytesIn.Store(0)
	b.bytesOut.Store(0)
	b.latencyMS.Store(0)
	doneCh := b.doneCh
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
	return nil
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
// proxy outbound. Exposed for tests.
func BuildSingBoxConfig(server proto.Server, socksPort, httpPort int) ([]byte, error) {
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
