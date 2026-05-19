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
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/DangerousANEN/mosaicvpn/internal/firewall"
	"github.com/DangerousANEN/mosaicvpn/internal/logx"
	"github.com/DangerousANEN/mosaicvpn/internal/proto"
	"github.com/DangerousANEN/mosaicvpn/internal/store"
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

	// sharedPorts records any inbound Windows Firewall openings we
	// created during Start (when ShareLAN was enabled) so Stop can
	// tear them back down. Keyed by firewall tag → port.
	sharedPorts map[string]int
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

// LogTail implements LogTailer. Returns the trailing n bytes of the
// live sing-box stderr log so callers (Speedtest / Verify) can attach
// the underlying cause when an HTTP probe through the proxy fails
// with "unexpected EOF" / "connection reset" / similar opaque
// network errors.
func (b *SingBoxBackend) LogTail(n int) string {
	if b.dataDir == "" {
		return ""
	}
	return readTail(filepath.Join(b.dataDir, "singbox.err.log"), n)
}

// LogPath implements LogPather. Returns the absolute path to the
// live sing-box stderr log so callers can surface it in error
// messages when LogTail comes back empty.  rc49 fallback for the
// "Speedtest EOF, no singbox tail" case.
func (b *SingBoxBackend) LogPath() string {
	if b.dataDir == "" {
		return ""
	}
	return filepath.Join(b.dataDir, "singbox.err.log")
}

// Stats implements Backend.
func (b *SingBoxBackend) Stats() (uint64, uint64, int) {
	return b.bytesIn.Load(), b.bytesOut.Load(), int(b.latencyMS.Load())
}

// Start implements Backend.
func (b *SingBoxBackend) Start(ctx context.Context, server proto.Server, prefs store.Prefs, rules []proto.Rule) error {
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

	// Pick SOCKS / HTTP / clash-api loopback ports.  Historical
	// defaults are 2080 / 2081 / 9090 with an ephemeral fallback
	// when the well-known port is already taken.  rc53 lets the
	// user pin a specific port via Prefs.SocksPort / HTTPPort —
	// when set we bind exactly that port (no fallback) so any app
	// the user pre-configured for "127.0.0.1:<my port>" stays
	// pointing at the running sing-box, instead of silently
	// landing on a random ephemeral that breaks the chain.
	socksPort := pickProxyPort(prefs.SocksPort, 2080)
	httpPort := pickProxyPort(prefs.HTTPPort, 2081)
	clashPort := pickPort(9090)
	if socksPort == 0 || httpPort == 0 {
		b.mu.Unlock()
		if prefs.SocksPort != 0 || prefs.HTTPPort != 0 {
			return fmt.Errorf("pinned proxy port already in use (socks=%d http=%d) — pick a different one in Folio → Verify → SOCKS / HTTP port", prefs.SocksPort, prefs.HTTPPort)
		}
		return errors.New("could not bind a free loopback port for sing-box proxies")
	}

	if prefs.TunnelMode == "tun" {
		// Stage wintun.dll alongside the data dir so sing-box's
		// LoadLibrary search picks it up. We only block Connect on a
		// missing DLL when the user actually asked for TUN — in proxy
		// mode wintun is irrelevant.
		if err := EnsureWintunDLL(b.dataDir); err != nil {
			b.mu.Unlock()
			return fmt.Errorf("tun:wintun_missing: %w", err)
		}
	}
	// rc49 — best-effort stage libcronet.dll for the naive
	// outbound (re-added in sing-box 1.13).  Soft-fails when the
	// DLL is not bundled (legacy builds, non-Windows hosts) — we
	// only need to actually fail the connect when the *server*
	// is naive and the DLL is missing.  EnsureLibcronetDLL
	// returns nil in both the "staged ok" and "not bundled, who
	// cares" cases, so we just log and move on.
	_ = EnsureLibcronetDLL(b.dataDir)

	cfg, err := BuildSingBoxConfig(server, prefs, rules, socksPort, httpPort, clashPort)
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
	// Surface the actual listen host so the UI can show a usable
	// LAN address. When ShareLAN is on sing-box binds 0.0.0.0 — but
	// 0.0.0.0 is meaningless to a peer ("connect to 0.0.0.0:2080"
	// won't work), so we publish the daemon machine's first non-
	// loopback v4 address instead. Falls back to loopback if no
	// LAN interface is up.
	listenHost := "127.0.0.1"
	if prefs.ShareLAN {
		listenHost = firstLANAddr()
		if listenHost == "" {
			listenHost = "0.0.0.0"
		}
	}
	b.socks = fmt.Sprintf("%s:%d", listenHost, socksPort)
	b.http = fmt.Sprintf("%s:%d", listenHost, httpPort)
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
	// select. Logged so users hunting "why is Atlas frozen" can
	// confirm the clash API is wired up at all without grepping the
	// generated config.
	logx.Info("sing-box backend metric pollers starting",
		"clash_api", clashEndpoint,
		"latency_target", net.JoinHostPort(firstNonEmpty(server.ResolvedIP, server.Address), strconv.Itoa(server.Port)),
	)
	go b.clashAPIPoll(cctx, clashEndpoint)
	go b.latencyPoll(cctx, server)

	// When the user has ShareLAN enabled, sing-box listens on
	// 0.0.0.0 but Windows Firewall silently drops inbound TCP from
	// the LAN on public / private profiles unless a rule exists for
	// our ports. Add two rules (one per listener) and remember them
	// for Stop. On Linux/macOS the firewall helpers are no-ops.
	if prefs.ShareLAN {
		b.mu.Lock()
		if b.sharedPorts == nil {
			b.sharedPorts = make(map[string]int)
		}
		b.mu.Unlock()
		for tag, port := range map[string]int{"socks": socksPort, "http": httpPort} {
			if err := firewall.AllowInbound(tag, port); err != nil {
				logx.Warn("firewall: allow inbound failed",
					"tag", tag, "port", port, "err", err)
				continue
			}
			b.mu.Lock()
			b.sharedPorts[tag] = port
			b.mu.Unlock()
			logx.Info("firewall: inbound allowed", "tag", tag, "port", port)
		}
	}

	return nil
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
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
	// 127.0.0.1 only — but still pin Proxy:nil so HTTP_PROXY env
	// vars on the user's machine never accidentally redirect this to
	// sing-box's own loopback SOCKS, which would deadlock the metric
	// channel against the very tunnel it's measuring.
	client := &http.Client{
		Timeout: 800 * time.Millisecond,
		Transport: &http.Transport{
			Proxy: nil,
			DialContext: (&net.Dialer{
				Timeout: 500 * time.Millisecond,
			}).DialContext,
		},
	}
	url := fmt.Sprintf("http://%s/connections", endpoint)
	// First few attempts may race the daemon's bootstrap. Back off in
	// 200 ms steps until either ctx fires or we get a 200.
	warm := time.NewTicker(200 * time.Millisecond)
	defer warm.Stop()
	warmDeadline := time.Now().Add(5 * time.Second)
	gotFirst := false
	for time.Now().Before(warmDeadline) {
		if ctx.Err() != nil {
			return
		}
		if b.fetchClashTotals(ctx, client, url) {
			gotFirst = true
			logx.Info("clash-api online", "endpoint", endpoint)
			break
		}
		select {
		case <-warm.C:
		case <-ctx.Done():
			return
		}
	}
	if !gotFirst {
		// Don't return — fall through into the steady-state ticker so
		// the poller keeps trying even if sing-box took longer than
		// 5 s to start serving /connections.
		logx.Warn("clash-api warm-up exceeded 5s; continuing to poll", "endpoint", endpoint)
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
	shared := b.sharedPorts
	b.sharedPorts = nil
	b.mu.Unlock()
	// Drop any LAN-share firewall rules we opened so disabling
	// ShareLAN (or fully disconnecting) immediately closes the
	// inbound path. Errors are logged but don't block shutdown.
	for tag, port := range shared {
		if err := firewall.DenyInbound(tag, port); err != nil {
			logx.Warn("firewall: deny inbound failed",
				"tag", tag, "port", port, "err", err)
			continue
		}
		logx.Info("firewall: inbound denied", "tag", tag, "port", port)
	}
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

// firstLANAddr returns the first non-loopback IPv4 address bound on
// the host, or "" if none is up. Used to render a usable LAN
// share address in the UI when ShareLAN is enabled — `0.0.0.0:2080`
// is correct on the bind side but useless when copy-pasted into a
// phone's manual proxy field.
func firstLANAddr() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	for _, a := range addrs {
		ipn, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		ip4 := ipn.IP.To4()
		if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() {
			continue
		}
		return ip4.String()
	}
	return ""
}

// pickPort returns preferred if it's free, otherwise an ephemeral
// loopback port. Returns 0 only if even the ephemeral allocation fails.
//
// preferred=0 is the explicit "give me anything" signal — in that case
// we always go through the ephemeral path so we can read the actual
// port the OS handed us; the previous implementation returned the
// literal 0 here, which surfaced to the user as the bogus
// "Verify: could not bind a free loopback port" error reported in rc24.
func pickPort(preferred int) int {
	if preferred > 0 {
		if l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", preferred)); err == nil {
			_ = l.Close()
			return preferred
		}
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

// pickPortStrict binds exactly preferred or returns 0; never falls back
// to an ephemeral port.  Used when the user explicitly pinned a SOCKS /
// HTTP port via Prefs — falling back silently would leave them with
// downstream apps pointed at the wrong listener.
func pickPortStrict(preferred int) int {
	if preferred <= 0 {
		return 0
	}
	l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", preferred))
	if err != nil {
		return 0
	}
	_ = l.Close()
	return preferred
}

// pickProxyPort returns the SOCKS / HTTP inbound port to bind, with
// strict-vs-fallback semantics driven by Prefs:
//   - prefs pinned (>0): bind exactly that port, never fall back; returns 0
//     when the pinned port is taken so the caller can surface a
//     pinned-port error.
//   - prefs unset (=0):  try the historical default first, fall back to an
//     ephemeral loopback port (preserves the rc24 behaviour for users
//     who never opened the new "SOCKS port" / "HTTP port" textboxes).
func pickProxyPort(pinned, fallback int) int {
	if pinned > 0 {
		return pickPortStrict(pinned)
	}
	return pickPort(fallback)
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
// /connections for live byte counters.
//
// When prefs.TunnelMode == "tun" the function additionally generates a
// `tun` inbound (interface_name=mosaic0, inet4_address=172.19.0.1/30,
// auto_route, strict_route, mtu=1500). The TUN stack defaults to
// gVisor unless prefs.TunStack overrides it. Loopback SOCKS / HTTP
// inbounds remain present so the existing UI-side proxy verifier and
// browser passthrough still work in TUN mode.
//
// Exposed for tests.
//
// rc48 — `rules` is the user-defined rule chain pulled from
// store.Snapshot().Rules. Rules with Action="direct" Enabled=true are
// plumbed into the sing-box `route.rules` array as bypass entries
// (their domain_suffix / ip_cidr targets skip the proxy outbound and
// dial through `direct` instead). System bypass entries for the
// geo-IP probe hosts mosaicd uses to detect the user's home
// location are always prepended; that way the user's "vous" pin
// keeps showing their real city even while the tunnel is up.
func BuildSingBoxConfig(server proto.Server, prefs store.Prefs, rules []proto.Rule, socksPort, httpPort, clashPort int) ([]byte, error) {
	out, err := outboundFor(server)
	if err != nil {
		return nil, err
	}
	applyAntiDPI(out, prefs)
	// LAN share toggle: when prefs.ShareLAN is true, bind the SOCKS
	// and HTTP inbounds on 0.0.0.0 so devices on the same Wi-Fi can
	// route through Mosaic by pointing their proxy at <host-LAN-IP>:port.
	// We never expose loopback-only services (clash API, daemon HTTP).
	listen := "127.0.0.1"
	if prefs.ShareLAN {
		listen = "0.0.0.0"
	}
	// rc51 — `sniff` on inbound listen fields was deprecated in
	// 1.11 and removed in 1.13.  The replacement is a rule action
	// `{action: "sniff"}` that buildRouteRules prepends to the
	// rule chain (so the route layer sees protocol/host metadata
	// before any other rule matches).  We keep the inbound
	// definitions otherwise unchanged.
	socksIn := map[string]any{
		"type":        "socks",
		"tag":         "socks-in",
		"listen":      listen,
		"listen_port": socksPort,
	}
	httpIn := map[string]any{
		"type":        "http",
		"tag":         "http-in",
		"listen":      listen,
		"listen_port": httpPort,
	}
	// LAN share auth: when prefs.ShareLAN exposes the proxies on
	// 0.0.0.0, require username/password if the user provided any.
	// sing-box's socks/http inbound `users` array gates access; an
	// empty/missing array leaves the listener anonymous (loopback
	// historic behaviour). Only attach when ShareLAN is on so a
	// loopback-only deployment never asks for a password.
	if prefs.ShareLAN && prefs.ShareUser != "" && prefs.SharePass != "" {
		users := []any{map[string]any{
			"username": prefs.ShareUser,
			"password": prefs.SharePass,
		}}
		socksIn["users"] = users
		httpIn["users"] = users
	}
	inbounds := []any{socksIn, httpIn}
	if prefs.TunnelMode == "tun" {
		inbounds = append(inbounds, tunInbound(prefs))
	}
	// rc51 — migrated DNS to sing-box 1.13's typed-server schema.
	// Legacy `address: "https://..."` / `address_resolver` /
	// per-server `strategy` were removed in 1.14 and FATAL in 1.13
	// without ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true.  The new
	// shape splits transport into `type: "https"` / `type: "udp"`
	// with bare host in `server`, hangs the resolver-for-resolver
	// off `domain_resolver`, and keeps `detour` / `tag` unchanged.
	// The historic `block` rcode server is gone — we no longer
	// reference it from any rule and the block special outbound is
	// removed in 1.13 anyway.
	//
	// rc52 fixup — local DNS now uses sing-box's built-in
	// `type: "local"` transport instead of `type: "udp"` over
	// 8.8.8.8 with `detour: "direct"`.  Reason: 1.13.7 added the
	// "detour to an empty direct outbound makes no sense"
	// validation, which FATALs at startup whenever a DNS server
	// detours to a `direct` outbound that has no custom dialer
	// options (commit SagerNet/sing-box@02727c2e5e).  The new
	// `type: "local"` transport delegates lookups to the OS
	// resolver (Windows: GetAddrInfoEx, Linux: /etc/resolv.conf)
	// without going through any outbound, which is the modern
	// idiom for "bypass the proxy for this DNS server".
	dnsServers := []any{
		map[string]any{
			"type":   "https",
			"tag":    "remote-doh",
			"server": "1.1.1.1",
			"detour": "proxy",
		},
		map[string]any{
			"type": "local",
			"tag":  "local",
		},
	}
	// Default DNS strategy: hand every captured DNS query to the
	// local resolver (8.8.8.8 over direct outbound) so the chicken-
	// and-egg of "DoH-via-proxy needs proxy needs DoH-via-proxy" can
	// never bite. The rc25 build set `final: remote-doh` here, which
	// meant a flaky proxy session left every captured query (Chrome
	// hits 30+ per page) sitting on a TLS handshake that was itself
	// being routed through the half-up proxy. Symptom on the user's
	// rc25 install: "Не удалось найти IP-адрес сервера 2ip.io".
	dnsFinal := "local"
	// rc49 — bumped the daemon-wide level from "warn" to "info" so
	// `singbox.err.log` actually contains a useful tail when
	// Speedtest decorates an "unexpected EOF" with `| singbox: …`.
	// At warn sing-box stays silent for connection drops; at info it
	// emits one line per outbound dial and per EOF, which is exactly
	// the diagnostic data the user asked for.  The URL-test path
	// overrides this to "trace" via prefs.URLTestLogLevel so the
	// ephemeral log captures every TLS / handshake event.
	logLevel := "info"
	if prefs.URLTestLogLevel != "" {
		logLevel = prefs.URLTestLogLevel
	}
	cfg := map[string]any{
		"log": map[string]any{
			"level":     logLevel,
			"timestamp": true,
		},
		// rc51 — `dns.rules` is now empty: the historic
		// `{outbound: "any", server: "local"}` rule was the
		// "outbound DNS rule item" pattern that 1.13 FATALs
		// without an env var.  Its job (resolve outbound dial
		// hostnames through `local`) is now done declaratively
		// via `route.default_domain_resolver` below.
		"dns": map[string]any{
			"servers":           dnsServers,
			"final":             dnsFinal,
			"strategy":          "ipv4_only",
			"independent_cache": true,
		},
		"inbounds": inbounds,
		"route": map[string]any{
			"final": "proxy",
			// auto_detect_interface lets sing-box's `direct`
			// outbound escape its own auto_route capture by
			// binding the underlying physical interface; without
			// this the local 8.8.8.8 resolver on the rc25 config
			// can route into TUN and loop, which is the same
			// failure mode the missing dns block produced in rc24.
			"auto_detect_interface": true,
			// rc51 — explicit default domain resolver replaces
			// the old `{outbound: "any", server: "local"}` DNS
			// rule.  Every outbound that has to resolve a host
			// (the proxy dialing its upstream, `direct` dialing
			// the geo-probe hosts, etc.) now uses `local` by
			// default.  Without this, sing-box 1.13 prints a
			// MISSING_DOMAIN_RESOLVER error and either FATALs or
			// dials through the system resolver depending on
			// version.
			"default_domain_resolver": "local",
			"rules":                   buildRouteRules(rules),
		},
	}
	// rc51 — wireguard / amneziawg moved out of `outbounds` and
	// into the dedicated `endpoints` array (1.11+ schema; the
	// legacy `wireguard` outbound was removed in 1.13).  Every
	// other protocol stays in `outbounds`.  The `direct` outbound
	// is always present so route rules with `outbound: "direct"`
	// still resolve.  `block` and `dns-out` outbounds are gone:
	// rule actions (`reject`, `hijack-dns`) cover their use cases
	// and sing-box 1.13 rejects both special outbound types as
	// "unknown outbound type".
	directOut := map[string]any{"type": "direct", "tag": "direct"}
	if IsEndpointProtocol(server.Protocol) {
		cfg["endpoints"] = []any{out}
		cfg["outbounds"] = []any{directOut}
	} else {
		cfg["outbounds"] = []any{out, directOut}
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

// tunInbound returns a sing-box `tun` inbound block configured for
// system-wide capture on Windows via Wintun. The stack is resolved
// from prefs.TunStack with a gVisor fallback — gVisor needs no
// elevated kernel-level routing primitives beyond the wintun adapter
// itself, which makes it the safest default. `auto_route` programs
// the OS routing table to send all v4/v6 traffic through the adapter,
// and `strict_route` forbids leaks if the daemon dies mid-session.
func tunInbound(prefs store.Prefs) map[string]any {
	stack := prefs.TunStack
	switch stack {
	case "system", "gvisor", "mixed":
	default:
		stack = "gvisor"
	}
	mtu := prefs.MTU
	if mtu <= 0 {
		mtu = 1500
	}
	return map[string]any{
		"type":           "tun",
		"tag":            "tun-in",
		"interface_name": "mosaic0",
		// sing-box 1.10+ replaces the legacy inet4_address /
		// inet6_address pair with a single `address` array. The new
		// form is forward-compatible with 1.12+ which drops the
		// legacy fields outright. /30 keeps the adapter's local
		// subnet at exactly two host addresses (gateway + client) —
		// matching the layout sing-box's gVisor stack expects.
		"address": []any{
			"172.19.0.1/30",
			"fd00:cafe::1/126",
		},
		"mtu":          mtu,
		"auto_route":   true,
		"strict_route": true,
		"stack":        stack,
		// rc51 — `sniff: true` was a legacy inbound field
		// removed in 1.13.  Sniffing is now a rule action
		// (`{action: "sniff"}`) emitted by buildRouteRules,
		// which catches all inbound traffic regardless of
		// listener type.
		// endpoint_independent_nat lets symmetric NAT'd UDP
		// flows (STUN, QUIC, WebRTC) survive the gVisor stack.
		"endpoint_independent_nat": true,
	}
	if runtime.GOOS == "windows" {
		m["auto_redirect"] = true
	}
	return m
}

// applyAntiDPI mutates the outbound config in-place to apply the
// user's anti-DPI overrides (uTLS fingerprint, TLS-fragment, mux,
// ECH).  Each toggle is best-effort: if the underlying outbound
// type does not support an option, we skip it silently rather than
// fail the connection.  Sing-box validates its own JSON on launch
// so an unsupported field prints to singbox.err.log either way.
func applyAntiDPI(out map[string]any, prefs store.Prefs) {
	if out == nil {
		return
	}
	// uTLS fingerprint override.  Only meaningful for TLS-bearing
	// outbounds (vless, trojan, vmess, anything with a "tls" block).
	// "auto" / "" leaves the subscription value alone.
	fp := strings.ToLower(strings.TrimSpace(prefs.DPIFingerprint))
	if fp != "" && fp != "auto" {
		if tlsAny, ok := out["tls"].(map[string]any); ok {
			tlsAny["enabled"] = true
			tlsAny["utls"] = map[string]any{
				"enabled":     true,
				"fingerprint": fp,
			}
		}
	}
	// ECH (Encrypted Client Hello).  sing-box accepts a tls.ech
	// object; with `enabled: true` and no static config it tries
	// to read the ECHConfigList from DNS HTTPS RR for the SNI.
	if prefs.DPIECH {
		if tlsAny, ok := out["tls"].(map[string]any); ok {
			tlsAny["enabled"] = true
			tlsAny["ech"] = map[string]any{"enabled": true}
		}
	}
	// TLS fragment.  sing-box's tls.fragment is structured as
	// {enabled: true, size: "1-3", sleep: "0-0"}.  We only set
	// `size` so the user picks the byte range; sleep stays at
	// the sing-box default.
	frag := strings.TrimSpace(prefs.DPIFragment)
	if frag != "" {
		if tlsAny, ok := out["tls"].(map[string]any); ok {
			tlsAny["enabled"] = true
			tlsAny["fragment"] = map[string]any{
				"enabled": true,
				"size":    frag,
			}
		}
	}
	// Mux.cool multiplexing.  Outbound-level multiplex object
	// {enabled: true, protocol: "smux", max_streams: N}.  "auto"
	// leaves max_streams unset (sing-box default = 0 = unlimited).
	mux := strings.TrimSpace(prefs.DPIMux)
	if mux != "" && mux != "off" {
		muxBlock := map[string]any{
			"enabled":  true,
			"protocol": "smux",
		}
		if mux != "auto" {
			if n, err := strconv.Atoi(mux); err == nil && n > 0 {
				muxBlock["max_streams"] = n
			}
		}
		out["multiplex"] = muxBlock
	}
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
		// Hysteria2 commonly advertises `alpn=h3` in URI / clash;
		// surface it on the TLS block so sing-box negotiates the
		// matching protocol with the upstream.
		if alpn := rs("alpn"); alpn != "" {
			var parts []string
			for _, p := range strings.Split(alpn, ",") {
				if t := strings.TrimSpace(p); t != "" {
					parts = append(parts, t)
				}
			}
			if len(parts) > 0 {
				tls["alpn"] = parts
			}
		}
		out["tls"] = tls
		if obfs := rs("obfs"); obfs != "" {
			out["obfs"] = map[string]any{
				"type":     obfs,
				"password": rs("obfs-password"),
			}
		}
		// Port-hopping: subscription URIs encode this as
		// `?mport=20000-50000` (or via clash `ports: 20000-50000`).
		// sing-box's hysteria2 outbound takes `server_ports` as an
		// array of `start:end` strings; we already normalise the
		// separator at parse time.
		if mport := rs("mport"); mport != "" {
			out["server_ports"] = []string{mport}
		} else if ports := rs("ports"); ports != "" {
			out["server_ports"] = []string{strings.ReplaceAll(ports, "-", ":")}
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
		// sing-box ≥1.4 ships a native `naive` outbound.  Schema:
		//   server, server_port, username, password, tls{enabled,
		//   server_name, insecure, alpn}.  `network` is a list filter
		//   (TCP/UDP) — sing-box defaults to TCP+UDP and we leave
		//   that alone; previous versions of this builder forced
		//   `network: udp` for naive+quic which broke modern
		//   sing-box because the naive outbound only carries TCP
		//   under the hood.
		out := map[string]any{
			"type":        "naive",
			"tag":         "proxy",
			"server":      s.Address,
			"server_port": s.Port,
			"username":    rs("username"),
			"password":    rs("password"),
		}
		scheme := strings.ToLower(rs("scheme"))
		if scheme == "" && s.Raw != nil {
			if u, ok := s.Raw["uri"].(string); ok {
				low := strings.ToLower(u)
				switch {
				case strings.HasPrefix(low, "naive+quic://"):
					scheme = "quic"
				case strings.HasPrefix(low, "naive+https://"):
					scheme = "https"
				}
			}
		}
		tls := map[string]any{"enabled": true}
		if sni := rs("sni"); sni != "" {
			tls["server_name"] = sni
		} else if scheme == "https" || scheme == "quic" {
			tls["server_name"] = s.Address
		}
		if rs("insecure") == "true" || rs("allow_insecure") == "1" || rs("skip-cert-verify") == "true" {
			tls["insecure"] = true
		}
		// Some naive servers expect h2 ALPN; pass through if set.
		if alpn := rs("alpn"); alpn != "" {
			var parts []string
			for _, p := range strings.Split(alpn, ",") {
				if t := strings.TrimSpace(p); t != "" {
					parts = append(parts, t)
				}
			}
			if len(parts) > 0 {
				tls["alpn"] = parts
			}
		}
		out["tls"] = tls
		return out, nil
	case proto.ProtoAmneziaWG:
		// rc51 — migrated from the legacy `wireguard` outbound (removed
		// in sing-box 1.13.0) to the modern `wireguard` endpoint
		// (`endpoints` array, available since 1.11.0).
		//
		// Schema rewrite:
		//   server / server_port (top-level)  ->  peers[0].address / port
		//   peer_public_key (top-level)       ->  peers[0].public_key
		//   pre_shared_key (top-level)        ->  peers[0].pre_shared_key
		//   reserved (top-level)              ->  peers[0].reserved
		//   local_address (top-level)         ->  address
		// `allowed_ips` is required on each peer in the new schema —
		// we default to `["0.0.0.0/0", "::/0"]` for full-tunnel
		// behaviour, matching what the legacy outbound implicitly
		// did.
		//
		// `amnezia_wg_settings` is dropped: vanilla sing-box never
		// implemented that sub-object (it lives in the amnezia-vpn
		// fork only), so emitting it never had any effect with the
		// bundled binary anyway.  AmneziaWG servers fall back to
		// plain WireGuard tunnels — bandwidth and routing keep
		// working, only the obfuscation layer is disabled.
		peer := map[string]any{
			"address":     s.Address,
			"port":        s.Port,
			"allowed_ips": []any{"0.0.0.0/0", "::/0"},
		}
		if pk := firstNonEmpty(rs("peer_public_key"), rs("public-key"), rs("public_key")); pk != "" {
			peer["public_key"] = pk
		}
		if psk := firstNonEmpty(rs("pre_shared_key"), rs("pre-shared-key"), rs("preshared-key")); psk != "" {
			peer["pre_shared_key"] = psk
		}
		if s.Raw != nil {
			if rsv, ok := s.Raw["reserved"]; ok {
				peer["reserved"] = rsv
			}
		}

		ep := map[string]any{
			"type":        "wireguard",
			"tag":         "proxy",
			"private_key": firstNonEmpty(rs("private_key"), rs("private-key")),
			"peers":       []any{peer},
		}
		if mtu := rs("mtu"); mtu != "" {
			if n, err := strconv.Atoi(mtu); err == nil && n > 0 {
				ep["mtu"] = n
			}
		}
		// `address` (was `local_address`): single string or []string.
		if s.Raw != nil {
			switch la := s.Raw["local_address"].(type) {
			case []any:
				addrs := make([]string, 0, len(la))
				for _, v := range la {
					if str, ok := v.(string); ok && str != "" {
						addrs = append(addrs, str)
					}
				}
				if len(addrs) > 0 {
					ep["address"] = addrs
				}
			case string:
				if la != "" {
					ep["address"] = []string{la}
				}
			}
			if _, ok := ep["address"]; !ok {
				// clash uses "ip" / "ipv6" instead of local_address.
				addrs := []string{}
				if v, ok := s.Raw["ip"].(string); ok && v != "" {
					addrs = append(addrs, v+"/32")
				}
				if v, ok := s.Raw["ipv6"].(string); ok && v != "" {
					addrs = append(addrs, v+"/128")
				}
				if len(addrs) > 0 {
					ep["address"] = addrs
				}
			}
		}
		return ep, nil
	}
	return nil, fmt.Errorf("unsupported protocol %q", s.Protocol)
}

// IsEndpointProtocol reports whether the given protocol is wired into
// sing-box as an `endpoints` entry rather than an `outbounds` entry.
// Since sing-box 1.13 removed the legacy `wireguard` outbound, every
// WireGuard-family protocol Mosaic ships goes through the endpoint
// path; everything else stays in `outbounds`.
func IsEndpointProtocol(p proto.Protocol) bool {
	return p == proto.ProtoAmneziaWG
}



func mergeMap(a, b map[string]any) map[string]any {
	for k, v := range b {
		a[k] = v
	}
	return a
}
