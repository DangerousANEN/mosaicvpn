package state

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
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
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/net/proxy"

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
	store   *store.Store

	cmd         *exec.Cmd
	cancel      context.CancelFunc
	doneCh      chan struct{}
	socks       string
	http        string
	clashApi    string // loopback address of the clash-api (e.g. "127.0.0.1:9090")
	clashSecret string
	lastExitErr string
	bytesIn     atomic.Uint64
	bytesOut    atomic.Uint64
	latencyMS   atomic.Int32

	// Rolling traffic series (for StatsBackend)
	seriesMu  sync.Mutex
	series    []proto.TrafficPoint
	peakConns atomic.Int32
}

// NewSingBoxBackend constructs a backend rooted at dataDir (where the
// generated config and stdout/stderr logs live). Pass an empty binary
// to auto-resolve via LocateSingBox; pass an explicit path (e.g. from a
// CLI flag or env var) to override.
func NewSingBoxBackend(binary, dataDir string, s *store.Store) *SingBoxBackend {
	return &SingBoxBackend{binary: binary, dataDir: dataDir, store: s}
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

// RuntimeHealth reports whether the sing-box child remains alive after Start.
// It deliberately reports only process lifecycle; endpoint reachability stays a
// client-side concern and is never used as a false tunnel-success signal.
func (b *SingBoxBackend) RuntimeHealth() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cmd == nil {
		if b.lastExitErr != "" {
			return errors.New(b.lastExitErr)
		}
		return errors.New("sing-box process is not running")
	}
	if b.doneCh == nil {
		return errors.New("sing-box process lifecycle is unavailable")
	}
	select {
	case <-b.doneCh:
		if b.lastExitErr != "" {
			return errors.New(b.lastExitErr)
		}
		return errors.New("sing-box process exited")
	default:
		return nil
	}
}

// preferredListenerPort obtains a valid requested port from a persisted
// loopback address. It deliberately falls back only when the preference is
// malformed, while pickPort below still finds an available alternative if the
// requested port is currently busy.
func preferredListenerPort(address string, fallback int) int {
	_, port, err := net.SplitHostPort(address)
	if err != nil {
		return fallback
	}
	value, err := strconv.Atoi(port)
	if err != nil || value < 1 || value > 65535 {
		return fallback
	}
	return value
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

	// Honour the addresses displayed and saved in preferences. If a requested
	// port is busy, pickPort selects a free fallback and exposes the actual
	// listener address through status.Proxies().
	socksPort := pickPort(preferredListenerPort(prefs.SocksAddr, 2080))
	httpPort := pickPort(preferredListenerPort(prefs.HTTPAddr, 2081))
	clashPort := pickPort(9090)
	if socksPort == 0 || httpPort == 0 || clashPort == 0 {
		b.mu.Unlock()
		return errors.New("could not bind a free loopback port for sing-box proxies")
	}

	// Generate a random clash-api secret so only we can query it.
	secret := genClashSecret()

	// Construct DNS config from prefs.
	dns := proto.DNSConfig{
		Mode:    prefs.DNSMode,
		Proxied: prefs.DNSProxied,
		Direct:  prefs.DNSDirect,
	}
	if dns.Mode == "" {
		dns.Mode = "fake-ip"
	}

	var allServers []proto.Server
	var egresses []proto.Egress
	if b.store != nil {
		allServers = b.store.Snapshot().Servers
		egresses = b.store.Snapshot().Egresses
	}

	cfg, err := BuildSingBoxConfigWithServers(server, socksPort, httpPort, prefs, rules, dns, clashPort, secret, allServers, egresses)
	if err != nil {
		b.mu.Unlock()
		return fmt.Errorf("build sing-box config: %w", err)
	}
	cfgPath := filepath.Join(b.dataDir, "singbox-current.json")
	if err := os.WriteFile(cfgPath, cfg, 0o600); err != nil {
		b.mu.Unlock()
		return fmt.Errorf("write sing-box config: %w", err)
	}

	// Validate against the exact bundled sing-box binary before creating any
	// runtime process or TUN adapter. This turns incompatible config fields into
	// a deterministic diagnostics response instead of an opaque HTTP 400.
	checkCtx, checkCancel := context.WithTimeout(ctx, 10*time.Second)
	check := exec.CommandContext(checkCtx, bin, "check", "-c", cfgPath, "-D", b.dataDir)
	hideConsoleWindow(check)
	check.Dir = b.dataDir
	checkOutput, checkErr := check.CombinedOutput()
	checkCancel()
	if checkErr != nil {
		b.mu.Unlock()
		detail := strings.TrimSpace(string(checkOutput))
		if detail == "" {
			detail = checkErr.Error()
		}
		return fmt.Errorf("sing-box config check: %s", detail)
	}

	cctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(cctx, bin, "run", "-c", cfgPath, "-D", b.dataDir)
	hideConsoleWindow(cmd)
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
	b.lastExitErr = ""
	b.socks = fmt.Sprintf("127.0.0.1:%d", socksPort)
	b.http = fmt.Sprintf("127.0.0.1:%d", httpPort)
	b.clashApi = fmt.Sprintf("127.0.0.1:%d", clashPort)
	b.clashSecret = secret
	b.bytesIn.Store(0)
	b.bytesOut.Store(0)
	b.latencyMS.Store(0)
	b.seriesMu.Lock()
	b.series = b.series[:0]
	b.seriesMu.Unlock()
	b.peakConns.Store(0)
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
		unexpected := err != nil && cctx.Err() == nil
		b.mu.Lock()
		if b.cmd == cmd {
			if unexpected {
				b.lastExitErr = fmt.Sprintf("sing-box exited unexpectedly: %v", err)
			}
			b.cmd = nil
			b.cancel = nil
			b.socks = ""
			b.http = ""
			b.clashApi = ""
			b.clashSecret = ""
		}
		b.mu.Unlock()
		if unexpected {
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

// HotReload updates the sing-box config file in place without restarting the process or dropping TUN.
func (b *SingBoxBackend) HotReload(ctx context.Context, server proto.Server, prefs store.Prefs, rules []proto.Rule) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.cmd == nil || b.cmd.Process == nil {
		return errors.New("sing-box process is not running")
	}

	socksPort := 2080
	httpPort := 2081
	clashPort := 9090
	if b.socks != "" {
		if _, p, err := net.SplitHostPort(b.socks); err == nil {
			socksPort, _ = strconv.Atoi(p)
		}
	}

	dns := proto.DNSConfig{
		Mode:    prefs.DNSMode,
		Proxied: prefs.DNSProxied,
		Direct:  prefs.DNSDirect,
	}

	var allServers []proto.Server
	var egresses []proto.Egress
	if b.store != nil {
		allServers = b.store.Snapshot().Servers
		egresses = b.store.Snapshot().Egresses
	}

	cfg, err := BuildSingBoxConfigWithServers(server, socksPort, httpPort, prefs, rules, dns, clashPort, b.clashSecret, allServers, egresses)
	if err != nil {
		return fmt.Errorf("build sing-box config for hot reload: %w", err)
	}

	cfgPath := filepath.Join(b.dataDir, "singbox-current.json")
	if err := os.WriteFile(cfgPath, cfg, 0o600); err != nil {
		return fmt.Errorf("write sing-box config for hot reload: %w", err)
	}

	_ = b.reloadClashConfig(cfgPath)

	logx.Info("sing-box configuration updated in-memory (hot-reload)", "server", server.Name)
	return nil
}

// Stop implements Backend.
func (b *SingBoxBackend) Stop(_ context.Context) error {
	b.mu.Lock()
	cancel := b.cancel
	doneCh := b.doneCh
	// Keep b.cmd non-nil while the process is shutting down so that a
	// concurrent Start() sees "already running" instead of racing on
	// port allocation. Cleared after the process has actually exited.
	b.cancel = nil
	b.doneCh = nil
	b.socks = ""
	b.http = ""
	b.clashApi = ""
	b.clashSecret = ""
	b.mu.Unlock()
	if cancel == nil {
		// Ensure stale cmd is cleared.
		b.mu.Lock()
		b.cmd = nil
		b.mu.Unlock()
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
	b.mu.Lock()
	b.cmd = nil
	b.mu.Unlock()
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
// document with a SOCKS and HTTP inbound on loopback, a single proxy
// outbound, optional DNS section, and routing rules derived from the
// Mosaic ruleset. Exposed for tests.
func BuildSingBoxConfig(server proto.Server, socksPort, httpPort int, prefs store.Prefs, rules []proto.Rule, dns proto.DNSConfig, clashPort int, clashSecret string) ([]byte, error) {
	return BuildSingBoxConfigWithServers(server, socksPort, httpPort, prefs, rules, dns, clashPort, clashSecret, nil, nil)
}

// singBoxDNSServer translates the user-facing resolver notation (for example
// udp://77.88.8.8 or https://1.1.1.1/dns-query) into sing-box 1.13's DNS
// server object. Passing a whole URL as `server` makes sing-box try to resolve
// the literal string as a domain and prevents the runtime from starting.
func singBoxDNSServer(tag, endpoint, detour string) map[string]any {
	endpoint = strings.TrimSpace(endpoint)
	if endpoint == "" {
		endpoint = "udp://1.1.1.1"
	}
	if !strings.Contains(endpoint, "://") {
		endpoint = "udp://" + endpoint
	}

	u, err := url.Parse(endpoint)
	if err != nil || u.Hostname() == "" {
		return map[string]any{
			"type":   "udp",
			"tag":    tag,
			"server": strings.TrimPrefix(endpoint, "udp://"),
		}
	}

	typeName := strings.ToLower(u.Scheme)
	switch typeName {
	case "udp", "tcp", "tls", "https", "quic", "http3":
	default:
		typeName = "udp"
	}
	if typeName == "http3" {
		typeName = "h3"
	}

	port := u.Port()
	if port == "" {
		switch typeName {
		case "https", "h3":
			port = "443"
		case "tls":
			port = "853"
		default:
			port = "53"
		}
	}
	portNumber, err := strconv.Atoi(port)
	if err != nil || portNumber < 1 || portNumber > 65535 {
		portNumber = 53
	}

	entry := map[string]any{
		"type":        typeName,
		"tag":         tag,
		"server":      u.Hostname(),
		"server_port": portNumber,
	}
	if (typeName == "https" || typeName == "h3") && u.EscapedPath() != "" {
		entry["path"] = u.EscapedPath()
	}
	if detour != "" {
		entry["detour"] = detour
	}
	return entry
}

// virtualGroupAllowsCandidate applies provider-supplied aggregate hints locally.
// The hints are used only for client selection; the generated outbounds still
// connect directly to the candidate node and never route payload traffic via
// MosaicVPN infrastructure.
func virtualGroupAllowsCandidate(group proto.Server, candidate proto.Server, targetCountry string) bool {
	if group.GroupTag == "rg-all" || group.GroupTag == "" {
		return true
	}

	switch group.GroupTag {
	case "auto-stable":
		if stable, present := outboundBoolHint(candidate, "mosaic_stable"); present {
			return stable
		}
		return true
	case "auto-speed":
		if eligible, present := outboundBoolHint(candidate, "mosaic_speed_eligible"); present {
			return eligible
		}
		return true
	case "auto-allowlist", "auto-whitelist":
		if allowed, present := outboundBoolHint(candidate, "mosaic_allowlist"); present {
			return allowed
		}
		nameLower := strings.ToLower(candidate.Name + " " + candidate.Tag)
		return strings.Contains(nameLower, "whitelist") || strings.Contains(nameLower, "4g") || strings.Contains(nameLower, "tspu") || candidate.Protocol == proto.ProtoVLESS
	}

	// Provider-annotated membership wins before GeoIP heuristics. The synthetic
	// candidate names contain "ca" ("mosaic-candidate-*"), so a name-substring
	// country match would put every candidate into the Canada group.
	for _, key := range []string{"mosaic_group_ids", "mosaic_candidate_groups"} {
		if list, ok := candidate.Raw[key].([]any); ok {
			for _, raw := range list {
				if gid, _ := raw.(string); gid != "" && gid == group.GroupTag {
					return true
				}
			}
		}
	}

	return targetCountry != "" && matchServerCountry(candidate, targetCountry)
}

func outboundBoolHint(server proto.Server, key string) (bool, bool) {
	value, present := server.Raw[key]
	flag, ok := value.(bool)
	return flag, present && ok
}

func outboundIntHint(server proto.Server, key string) int {
	value, present := server.Raw[key]
	if !present {
		return 0
	}
	switch number := value.(type) {
	case float64:
		return int(number)
	case float32:
		return int(number)
	case int:
		return number
	case int64:
		return int(number)
	}
	return 0
}

func BuildSingBoxConfigWithServers(server proto.Server, socksPort, httpPort int, prefs store.Prefs, rules []proto.Rule, dns proto.DNSConfig, clashPort int, clashSecret string, allServers []proto.Server, egresses []proto.Egress) ([]byte, error) {
	var proxyOutbounds []any

	if server.IsVirtualGroup {
		targetURL := "https://cp.cloudflare.com/generate_204"
		if server.Category == "whitelist" || server.GroupTag == "auto-whitelist" || server.Country == "RU" {
			targetURL = "https://yandex.ru/generate_204"
		}

		var childNodes []proto.Server
		targetCountry := server.Country
		if targetCountry == "" {
			gt := strings.ToLower(server.GroupTag + " " + server.ID)
			switch {
			case strings.Contains(gt, "de"):
				targetCountry = "DE"
			case strings.Contains(gt, "nl"):
				targetCountry = "NL"
			case strings.Contains(gt, "us"):
				targetCountry = "US"
			case strings.Contains(gt, "ca"):
				targetCountry = "CA"
			case strings.Contains(gt, "fr"):
				targetCountry = "FR"
			case strings.Contains(gt, "sg"):
				targetCountry = "SG"
			case strings.Contains(gt, "gb") || strings.Contains(gt, "uk"):
				targetCountry = "GB"
			case strings.Contains(gt, "fi"):
				targetCountry = "FI"
			case strings.Contains(gt, "ru"):
				targetCountry = "RU"
			}
		}

		for _, sv := range allServers {
			if sv.IsVirtualGroup {
				continue
			}
			if server.SubscriptionID != "" && sv.SubscriptionID != server.SubscriptionID {
				continue
			}
			if virtualGroupAllowsCandidate(server, sv, targetCountry) {
				childNodes = append(childNodes, sv)
			}
		}

		var nodeTags []string
		for i, node := range childNodes {
			nodeTag := fmt.Sprintf("node-%s-%d", node.ID, i)
			nodeOut, err := outboundForWithTag(node, nodeTag)
			if err == nil {
				proxyOutbounds = append(proxyOutbounds, nodeOut)
				nodeTags = append(nodeTags, nodeTag)
			}
		}

		if len(nodeTags) == 0 {
			// A protected Smart Group must never silently degrade to direct
			// traffic. The caller receives a typed configuration failure and can
			// refresh the provider manifest instead of bypassing the group policy.
			return nil, fmt.Errorf("smart group %q has no usable provider candidates", server.Name)
		}

		intervalSeconds := outboundIntHint(server, "mosaic_ping_interval")
		if intervalSeconds <= 0 {
			intervalSeconds = 15
		}
		// urltest owns the active outbound locally. If its current candidate
		// fails a probe, sing-box selects another direct candidate. Existing
		// flows are left intact; new traffic follows the healthy route.
		groupOut := map[string]any{
			"type":                        "urltest",
			"tag":                         "proxy",
			"outbounds":                   nodeTags,
			"url":                         targetURL,
			"interval":                    fmt.Sprintf("%ds", intervalSeconds),
			"tolerance":                   20,
			"idle_timeout":                "30m",
			"interrupt_exist_connections": false,
		}
		proxyOutbounds = append([]any{groupOut}, proxyOutbounds...)
	} else {
		out, err := outboundForWithTag(server, "proxy")
		if err != nil {
			return nil, err
		}
		proxyOutbounds = append(proxyOutbounds, out)
	}

	listenAddr := "127.0.0.1"
	if prefs.AllowLAN || prefs.ShareLAN {
		listenAddr = "0.0.0.0"
	}

	inbounds := []any{
		map[string]any{
			"type":        "socks",
			"tag":         "socks-in",
			"listen":      listenAddr,
			"listen_port": socksPort,
		},
		map[string]any{
			"type":        "http",
			"tag":         "http-in",
			"listen":      listenAddr,
			"listen_port": httpPort,
		},
	}

	if prefs.TunnelMode == "tun" || prefs.TunnelMode == "" {
		inbounds = append(inbounds, map[string]any{
			"type":         "tun",
			"tag":          "tun-in",
			"address":      []string{"172.19.0.1/30"},
			"auto_route":   true,
			"strict_route": true,
			"stack":        "gvisor",
		})
	}

	allOutbounds := append(proxyOutbounds,
		map[string]any{"type": "direct", "tag": "direct"},
		map[string]any{"type": "block", "tag": "block"},
	)

	// ---- Egress listeners (additional inbounds with per-egress routing) ----
	var egressRouteRules []any
	if len(egresses) > 0 {
		for _, eg := range egresses {
			if !eg.Active || eg.Port == 0 {
				continue
			}
			egressTag := fmt.Sprintf("egress-%s", eg.ID)
			egressOutboundTag := fmt.Sprintf("egress-out-%s", eg.ID)

			// Inbound: SOCKS5 or HTTP or mixed on the egress port
			egListen := eg.Listen
			if egListen == "" {
				egListen = "127.0.0.1"
			}
			switch eg.Type {
			case "socks", "socks5":
				inbounds = append(inbounds, map[string]any{
					"type":        "socks",
					"tag":         egressTag,
					"listen":      egListen,
					"listen_port": eg.Port,
				})
			case "http":
				inbounds = append(inbounds, map[string]any{
					"type":        "http",
					"tag":         egressTag,
					"listen":      egListen,
					"listen_port": eg.Port,
				})
			default: // "mixed" or empty
				inbounds = append(inbounds, map[string]any{
					"type":        "mixed",
					"tag":         egressTag,
					"listen":      egListen,
					"listen_port": eg.Port,
				})
			}

			// Outbound: if GroupID set → urltest group with matching servers,
			// else if ServerID set → specific server outbound, else → "proxy" (default)
			if eg.GroupID != "" {
				// Find servers matching this group tag
				var groupNodes []string
				for i, sv := range allServers {
					if sv.IsVirtualGroup {
						continue
					}
					if sv.GroupTag == eg.GroupID || sv.SubscriptionID == eg.GroupID {
						nodeTag := fmt.Sprintf("en-%s-%d", eg.ID, i)
						nodeOut, err := outboundForWithTag(sv, nodeTag)
						if err == nil {
							allOutbounds = append(allOutbounds, nodeOut)
							groupNodes = append(groupNodes, nodeTag)
						}
					}
				}
				if len(groupNodes) == 0 {
					groupNodes = []string{"direct"}
				}
				allOutbounds = append(allOutbounds, map[string]any{
					"type":                        "urltest",
					"tag":                         egressOutboundTag,
					"outbounds":                   groupNodes,
					"url":                         "https://cp.cloudflare.com/generate_204",
					"interval":                    "15s",
					"tolerance":                   30,
					"interrupt_exist_connections": false,
				})
			} else if eg.ServerID != "" {
				// Find the specific server
				var found *proto.Server
				for i, sv := range allServers {
					if sv.ID == eg.ServerID {
						found = &allServers[i]
						break
					}
				}
				if found != nil {
					egOut, err := outboundForWithTag(*found, egressOutboundTag)
					if err == nil {
						allOutbounds = append(allOutbounds, egOut)
					} else {
						egressOutboundTag = "proxy"
					}
				} else {
					egressOutboundTag = "proxy"
				}
			} else {
				// Default → use main proxy
				egressOutboundTag = "proxy"
			}

			// Route rule: traffic from this egress inbound → egress outbound
			egressRouteRules = append(egressRouteRules, map[string]any{
				"inbound":  egressTag,
				"outbound": egressOutboundTag,
			})
		}
	}

	cfg := map[string]any{
		"log": map[string]any{
			"level":     "warn",
			"timestamp": true,
		},
		"inbounds":  inbounds,
		"outbounds": allOutbounds,
		"experimental": map[string]any{
			"clash_api": map[string]any{
				"external_controller": fmt.Sprintf("127.0.0.1:%d", clashPort),
				"secret":              clashSecret,
			},
		},
	}

	// ---- DNS section (sing-box 1.13+ server format) ----
	dnsServerTag := "dns-direct"
	if dns.Mode != "disabled" {
		servers := []any{}
		// Primary resolver (direct / real DNS). Preferences retain URL notation,
		// but sing-box requires host, port and transport in separate fields.
		primaryTag := "dns-primary"
		servers = append(servers, singBoxDNSServer(primaryTag, dns.Direct, ""))
		// Proxied resolver is optional and uses the selected tunnel outbound.
		if dns.Proxied != "" {
			servers = append(servers, singBoxDNSServer("dns-proxied", dns.Proxied, "proxy"))
		}
		// FakeIP server (new format: standalone server object)
		if dns.Mode == "fake-ip" {
			fakeIPEntry := map[string]any{
				"type":        "fakeip",
				"tag":         "dns-fakeip",
				"inet4_range": "198.18.0.0/15",
			}
			if dns.FakeIPRange != "" {
				fakeIPEntry["inet4_range"] = dns.FakeIPRange
			}
			servers = append(servers, fakeIPEntry)
		}
		dnsRules := []any{}
		if dns.Mode == "fake-ip" {
			dnsRules = append(dnsRules, map[string]any{
				"query_type": []string{"A", "AAAA"},
				"server":     "dns-fakeip",
			})
		}
		dnsBlock := map[string]any{
			"servers": servers,
		}
		if len(dnsRules) > 0 {
			dnsBlock["rules"] = dnsRules
		}
		if dns.DisableCache {
			dnsBlock["cache"] = false
		}
		if dns.DisableFallback {
			dnsBlock["disable_fallback"] = true
		}
		if len(dns.Hosts) > 0 {
			dnsBlock["hosts"] = dns.Hosts
		}
		cfg["dns"] = dnsBlock
		// Use the primary DNS server as the default domain resolver
		dnsServerTag = primaryTag
	}

	// ---- Route rules ----
	routeRules := []any{
		map[string]any{"protocol": "dns", "action": "hijack-dns"},
	}
	if len(prefs.BypassProcesses) > 0 {
		routeRules = append(routeRules, map[string]any{
			"process_name": prefs.BypassProcesses,
			"outbound":     "direct",
		})
	}
	if prefs.BlockIPv6 {
		routeRules = append(routeRules, map[string]any{
			"ip_version": 6,
			"outbound":   "block",
		})
	}
	for _, r := range rules {
		sr := ruleToSingBox(r)
		if sr != nil {
			routeRules = append(routeRules, sr)
		}
	}
	// Egress routing rules must come BEFORE the final "proxy" fallback
	// so traffic from egress inbounds goes to their dedicated outbounds.
	if len(egressRouteRules) > 0 {
		routeRules = append(egressRouteRules, routeRules...)
	}

	routeBlock := map[string]any{
		"final":                   "proxy",
		"rules":                   routeRules,
		"default_domain_resolver": dnsServerTag,
		// Desktop TUN needs to bind outbound dials to the default physical
		// interface; otherwise the upstream transport can re-enter its own TUN
		// route and fail before the proxy handshake reaches the provider.
		"auto_detect_interface": true,
	}
	if dns.Mode == "disabled" {
		delete(routeBlock, "default_domain_resolver")
	}
	cfg["route"] = routeBlock

	return json.MarshalIndent(cfg, "", "  ")
}

// ruleToSingBox converts a proto.Rule into a sing-box route rule map.
// Returns nil if the rule has no match conditions.
func ruleToSingBox(r proto.Rule) map[string]any {
	if r.ID == "" && r.Match.Empty() {
		return nil
	}

	outbound := "proxy"
	switch r.Action {
	case proto.ActionDirect:
		outbound = "direct"
	case proto.ActionBlock:
		outbound = "block"
	}

	rule := map[string]any{"outbound": outbound}

	// Match fields
	m := r.Match
	if len(m.DomainSuffix) > 0 {
		rule["domain_suffix"] = m.DomainSuffix
	}
	if len(m.Domain) > 0 {
		rule["domain"] = m.Domain
	}
	if len(m.DomainKeyword) > 0 {
		rule["domain_keyword"] = m.DomainKeyword
	}
	if len(m.IPCIDR) > 0 {
		rule["ip_cidr"] = m.IPCIDR
	}
	if len(m.Process) > 0 {
		rule["process_name"] = m.Process
	}
	if len(m.Port) > 0 {
		rule["port"] = m.Port
	}
	if len(m.GeoSite) > 0 {
		rule["geosite"] = m.GeoSite
	}
	if len(m.GeoIP) > 0 {
		rule["geoip"] = m.GeoIP
	}

	return rule
}

// outboundFor builds the sing-box outbound block matching the server's
// protocol with tag "proxy".
func outboundFor(s proto.Server) (map[string]any, error) {
	return outboundForWithTag(s, "proxy")
}

// outboundForWithTag builds a sing-box outbound block with a custom tag name.
func outboundForWithTag(s proto.Server, tag string) (map[string]any, error) {
	if tag == "" {
		tag = "proxy"
	}
	if s.IsVirtualGroup {
		targetURL := "https://cp.cloudflare.com/generate_204"
		if s.Category == "whitelist" || s.GroupTag == "auto-whitelist" || s.Country == "RU" {
			targetURL = "https://yandex.ru/generate_204"
		}
		return map[string]any{
			"type":                        "urltest",
			"tag":                         tag,
			"url":                         targetURL,
			"interval":                    "15s",
			"tolerance":                   30,
			"idle_timeout":                "30m",
			"interrupt_exist_connections": false,
		}, nil
	}

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
			"tag":         tag,
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
			"tag":         tag,
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
			"tag":         tag,
			"server":      s.Address,
			"server_port": s.Port,
			"method":      rs("method"),
			"password":    rs("password"),
		}
		return out, nil
	case proto.ProtoVMess:
		out := map[string]any{
			"type":        "vmess",
			"tag":         tag,
			"server":      s.Address,
			"server_port": s.Port,
			"uuid":        rs("uuid"),
		}
		if aid := rs("alter_id"); aid != "" {
			if n, err := strconv.Atoi(aid); err == nil {
				out["alter_id"] = n
			}
		}
		if sec := rs("security"); sec != "" {
			out["security"] = sec
		}
		network := rs("network")
		// TLS block — same pattern as vless
		tlsBlock := map[string]any{}
		if rs("sni") != "" || rs("tls") == "tls" {
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
			if rs("insecure") == "true" || rs("skip-cert-verify") == "true" {
				tlsBlock["insecure"] = true
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
		case "http":
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

	case proto.ProtoTrojan:
		out := map[string]any{
			"type":        "trojan",
			"tag":         tag,
			"server":      s.Address,
			"server_port": s.Port,
			"password":    rs("password"),
		}
		// TLS block — Trojan always uses TLS
		tlsBlock := map[string]any{"enabled": true}
		if sni := rs("sni"); sni != "" {
			tlsBlock["server_name"] = sni
		}
		if fp := rs("fingerprint"); fp != "" {
			tlsBlock["utls"] = map[string]any{
				"enabled":     true,
				"fingerprint": fp,
			}
		}
		if rs("insecure") == "true" || rs("skip-cert-verify") == "true" {
			tlsBlock["insecure"] = true
		}
		out["tls"] = tlsBlock
		// Transport — same ws/grpc/http patterns as vless
		network := rs("network")
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
		case "http":
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

	case proto.ProtoNaive:
		out := map[string]any{
			"type":        "naive",
			"tag":         tag,
			"server":      s.Address,
			"server_port": s.Port,
			"username":    rs("username"),
			"password":    rs("password"),
		}
		if tlsSNI := rs("sni"); tlsSNI != "" {
			out["tls"] = map[string]any{
				"enabled":     true,
				"server_name": tlsSNI,
			}
		}
		return out, nil
	case proto.ProtoAmneziaWG:
		return nil, fmt.Errorf("protocol %s not supported by sing-box; use a different station", s.Protocol)
	}
	return nil, fmt.Errorf("unsupported protocol %q", s.Protocol)
}

func matchServerCountry(sv proto.Server, targetCountry string) bool {
	if targetCountry == "" {
		return false
	}
	if sv.Country != "" && strings.EqualFold(sv.Country, targetCountry) {
		return true
	}
	// Candidate nodes carry authoritative GeoIP from the provider collector
	// (mosaic_country → Server.Country). Never guess their country from the
	// synthetic name "mosaic-candidate-*": its "ca" substring would match the
	// whole pool into the Canada group.
	if _, isCandidate := sv.Raw["mosaic_client_candidate"]; isCandidate {
		return false
	}
	if _, hasGroups := sv.Raw["mosaic_group_ids"]; hasGroups {
		return false
	}
	tc := strings.ToLower(targetCountry)
	haystack := strings.ToLower(sv.Name + " " + sv.Tag + " " + sv.Address + " " + sv.City)

	switch tc {
	case "de":
		return strings.Contains(haystack, "de") || strings.Contains(haystack, "germany") || strings.Contains(haystack, "frankfurt") || strings.Contains(haystack, "berlin") || strings.Contains(haystack, "nuremberg")
	case "nl":
		return strings.Contains(haystack, "nl") || strings.Contains(haystack, "netherlands") || strings.Contains(haystack, "amsterdam")
	case "us":
		return strings.Contains(haystack, "us") || strings.Contains(haystack, "usa") || strings.Contains(haystack, "united states") || strings.Contains(haystack, "new york") || strings.Contains(haystack, "los angeles") || strings.Contains(haystack, "miami") || strings.Contains(haystack, "dallas") || strings.Contains(haystack, "chicago") || strings.Contains(haystack, "ashburn") || strings.Contains(haystack, "seattle")
	case "ca":
		return strings.Contains(haystack, "ca") || strings.Contains(haystack, "canada") || strings.Contains(haystack, "toronto") || strings.Contains(haystack, "montreal")
	case "fr":
		return strings.Contains(haystack, "fr") || strings.Contains(haystack, "france") || strings.Contains(haystack, "paris")
	case "sg":
		return strings.Contains(haystack, "sg") || strings.Contains(haystack, "singapore")
	case "gb", "uk":
		return strings.Contains(haystack, "gb") || strings.Contains(haystack, "uk") || strings.Contains(haystack, "london") || strings.Contains(haystack, "united kingdom")
	case "fi":
		return strings.Contains(haystack, "fi") || strings.Contains(haystack, "finland") || strings.Contains(haystack, "helsinki")
	case "ru":
		return strings.Contains(haystack, "ru") || strings.Contains(haystack, "russia") || strings.Contains(haystack, "moscow") || strings.Contains(haystack, "spb") || strings.Contains(haystack, "saint petersburg")
	default:
		return strings.Contains(haystack, tc)
	}
}

func mergeMap(a, b map[string]any) map[string]any {
	for k, v := range b {
		a[k] = v
	}
	return a
}

// genClashSecret returns a 16-byte hex string used as the clash-api bearer
// secret.  It is generated per-session so external processes on the same
// machine cannot query the running sing-box instance.
func genClashSecret() string {
	var buf [16]byte
	_, _ = rand.Read(buf[:])
	return hex.EncodeToString(buf[:])
}

// ---------------------------------------------------------------------------
// Clash API client helpers
// ---------------------------------------------------------------------------

// clashGet performs an authenticated GET to the running sing-box clash-api.
func (b *SingBoxBackend) clashGet(path string) ([]byte, error) {
	b.mu.Lock()
	addr := b.clashApi
	secret := b.clashSecret
	b.mu.Unlock()
	if addr == "" {
		return nil, errors.New("sing-box is not running")
	}
	req, err := http.NewRequest("GET", "http://"+addr+path, nil)
	if err != nil {
		return nil, err
	}
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
	}
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("clash-api %s: %s", path, resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 1<<20))
}

// reloadClashConfig tells the running sing-box process via Clash REST API to reload configuration.
func (b *SingBoxBackend) reloadClashConfig(cfgPath string) error {
	b.mu.Lock()
	addr := b.clashApi
	secret := b.clashSecret
	b.mu.Unlock()
	if addr == "" {
		return errors.New("sing-box is not running")
	}

	body, err := json.Marshal(map[string]any{"path": cfgPath})
	if err != nil {
		return err
	}

	req, err := http.NewRequest("PUT", "http://"+addr+"/configs?force=true", strings.NewReader(string(body)))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
	}

	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return nil
}

// clashPost performs an authenticated POST (no body) to the clash-api.
func (b *SingBoxBackend) clashPost(path string) error {
	b.mu.Lock()
	addr := b.clashApi
	secret := b.clashSecret
	b.mu.Unlock()
	if addr == "" {
		return errors.New("sing-box is not running")
	}
	req, err := http.NewRequest("POST", "http://"+addr+path, nil)
	if err != nil {
		return err
	}
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
	}
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 && resp.StatusCode != 204 {
		return fmt.Errorf("clash-api %s: %s", path, resp.Status)
	}
	return nil
}

// ---------------------------------------------------------------------------
// ConnectionBackend implementation
// ---------------------------------------------------------------------------

// clashConn is the JSON shape returned by clash-api /connections.
type clashConn struct {
	ID       string `json:"id"`
	Network  string `json:"network"`
	Metadata struct {
		Network         string `json:"network"`
		DestinationIP   string `json:"destinationIP"`
		DestinationPort string `json:"destinationPort"`
		SourceIP        string `json:"sourceIP"`
		SourcePort      string `json:"sourcePort"`
		ProcessPath     string `json:"processPath"`
		Host            string `json:"host"`
	} `json:"metadata"`
	Upload   int64    `json:"upload"`
	Download int64    `json:"download"`
	Start    string   `json:"start"`
	Chains   []string `json:"chains"`
	Rule     string   `json:"rule"`
}

type clashConnsResp struct {
	Connections []clashConn `json:"connections"`
	Upload      int64       `json:"upload"`
	Download    int64       `json:"download"`
}

// Connections implements ConnectionBackend.
func (b *SingBoxBackend) Connections() []proto.Connection {
	data, err := b.clashGet("/connections")
	if err != nil {
		return []proto.Connection{}
	}
	var resp clashConnsResp
	if err := json.Unmarshal(data, &resp); err != nil {
		return []proto.Connection{}
	}

	conns := make([]proto.Connection, 0, len(resp.Connections))
	for _, c := range resp.Connections {
		net := c.Network
		if net == "" {
			net = c.Metadata.Network
		}
		domain := c.Metadata.Host
		ip := c.Metadata.DestinationIP
		port, _ := strconv.Atoi(c.Metadata.DestinationPort)
		chain := ""
		if len(c.Chains) > 0 {
			chain = strings.Join(c.Chains, " → ")
		}
		conns = append(conns, proto.Connection{
			ID:         c.ID,
			Network:    net,
			Outbound:   chain,
			Domain:     domain,
			IP:         ip,
			Port:       port,
			SourceIP:   c.Metadata.SourceIP,
			SourcePort: func() int { p, _ := strconv.Atoi(c.Metadata.SourcePort); return p }(),
			Process:    c.Metadata.ProcessPath,
			Upload:     uint64(c.Upload),
			Download:   uint64(c.Download),
			StartAt:    func() time.Time { t, _ := time.Parse(time.RFC3339, c.Start); return t }(),
			Chain:      chain,
			Rule:       c.Rule,
		})
	}

	// Track peak connection count.
	n := int32(len(conns))
	for {
		peak := b.peakConns.Load()
		if n <= peak || b.peakConns.CompareAndSwap(peak, n) {
			break
		}
	}

	return conns
}

// CloseConnection implements ConnectionBackend.
func (b *SingBoxBackend) CloseConnection(id string) error {
	return b.clashPost("/connections/" + url.PathEscape(id))
}

// CloseAllConnections implements ConnectionBackend.
func (b *SingBoxBackend) CloseAllConnections() error {
	return b.clashPost("/connections")
}

// ---------------------------------------------------------------------------
// StatsBackend implementation
// ---------------------------------------------------------------------------

// TrafficStats implements StatsBackend.
func (b *SingBoxBackend) TrafficStats() proto.TrafficStats {
	in := b.bytesIn.Load()
	out := b.bytesOut.Load()

	// Try to enrich from clash-api realtime traffic.
	var connCount int
	if data, err := b.clashGet("/connections"); err == nil {
		var resp clashConnsResp
		if json.Unmarshal(data, &resp) == nil {
			connCount = len(resp.Connections)
			// clash-api returns aggregate up/down across all connections.
			if resp.Upload > 0 || resp.Download > 0 {
				// These are cumulative since session start; use them
				// if our atomic counters haven't been populated yet.
				if out == 0 {
					out = uint64(resp.Upload)
				}
				if in == 0 {
					in = uint64(resp.Download)
				}
			}
		}
	}

	// Update series with the latest data point.
	now := time.Now()
	pt := proto.TrafficPoint{Timestamp: now, BytesIn: in, BytesOut: out}
	b.seriesMu.Lock()
	b.series = append(b.series, pt)
	if len(b.series) > 120 {
		b.series = b.series[len(b.series)-120:]
	}
	seriesCopy := make([]proto.TrafficPoint, len(b.series))
	copy(seriesCopy, b.series)
	b.seriesMu.Unlock()

	peak := int(b.peakConns.Load())
	if connCount > peak {
		peak = connCount
	}

	return proto.TrafficStats{
		TotalBytesIn:  in,
		TotalBytesOut: out,
		Series:        seriesCopy,
		ConnCount:     connCount,
		PeakConnCount: peak,
	}
}

// ResetStats implements StatsBackend.
func (b *SingBoxBackend) ResetStats() error {
	b.bytesIn.Store(0)
	b.bytesOut.Store(0)
	b.latencyMS.Store(0)
	b.peakConns.Store(0)
	b.seriesMu.Lock()
	b.series = b.series[:0]
	b.seriesMu.Unlock()
	return nil
}

// ---------------------------------------------------------------------------
// TestBackend implementation
// ---------------------------------------------------------------------------

// TestURL measures latency to a URL through the active SOCKS proxy.
func (b *SingBoxBackend) TestURL(ctx context.Context, target string) (proto.TestResult, error) {
	b.mu.Lock()
	socks := b.socks
	b.mu.Unlock()
	if socks == "" {
		return proto.TestResult{}, errors.New("sing-box is not running")
	}

	// Parse the URL to extract host for the result.
	_, err := url.Parse(target)
	if err != nil {
		return proto.TestResult{}, fmt.Errorf("parse URL: %w", err)
	}

	dialer, err := proxy.SOCKS5("tcp", socks, nil, &net.Dialer{})
	if err != nil {
		return proto.TestResult{}, fmt.Errorf("socks5 dial: %w", err)
	}

	transport := &http.Transport{
		DialContext: func(_ context.Context, network, addr string) (net.Conn, error) {
			return dialer.Dial(network, addr)
		},
	}
	client := &http.Client{
		Transport: transport,
		Timeout:   10 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse // don't follow; we just want latency
		},
	}

	start := time.Now()
	resp, err := client.Get(target)
	latency := time.Since(start)
	if err != nil {
		_ = ctx
		return proto.TestResult{
			ServerID:  "",
			LatencyMS: int(latency.Milliseconds()),
			Error:     err.Error(),
			TestedAt:  start,
		}, nil
	}
	resp.Body.Close()

	return proto.TestResult{
		LatencyMS: int(latency.Milliseconds()),
		TestedAt:  start,
	}, nil
}

// TestIP queries the apparent egress IP through the active tunnel.
func (b *SingBoxBackend) TestIP(ctx context.Context) (proto.IPInfo, error) {
	b.mu.Lock()
	socks := b.socks
	b.mu.Unlock()
	if socks == "" {
		return proto.IPInfo{}, errors.New("sing-box is not running")
	}

	dialer, err := proxy.SOCKS5("tcp", socks, nil, &net.Dialer{})
	if err != nil {
		return proto.IPInfo{}, fmt.Errorf("socks5 dial: %w", err)
	}

	transport := &http.Transport{
		DialContext: func(_ context.Context, network, addr string) (net.Conn, error) {
			return dialer.Dial(network, addr)
		},
	}
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}

	req, _ := http.NewRequestWithContext(ctx, "GET", "https://api.ipify.org?format=json", nil)
	resp, err := client.Do(req)
	if err != nil {
		return proto.IPInfo{}, err
	}
	defer resp.Body.Close()

	var ipResp struct {
		IP string `json:"ip"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&ipResp); err != nil {
		return proto.IPInfo{}, err
	}

	// Best-effort geo lookup via ip-api.com (no key needed for low rate).
	ipInfo := proto.IPInfo{IP: ipResp.IP}
	req2, _ := http.NewRequestWithContext(ctx, "GET", "http://ip-api.com/json/"+ipResp.IP, nil)
	client2 := &http.Client{Timeout: 5 * time.Second}
	resp2, err := client2.Do(req2)
	if err == nil {
		defer resp2.Body.Close()
		var geo struct {
			CountryCode string `json:"countryCode"`
			Country     string `json:"country"`
			City        string `json:"city"`
			ISP         string `json:"isp"`
			AS          string `json:"as"`
		}
		if json.NewDecoder(resp2.Body).Decode(&geo) == nil {
			ipInfo.Country = geo.Country
			ipInfo.City = geo.City
			ipInfo.ISP = geo.ISP
			ipInfo.ASN = geo.AS
		}
	}

	return ipInfo, nil
}

// SpeedTest runs a bounded HTTPS throughput probe through the active tunnel.
// It deliberately avoids Ookla and accepts provider-supplied HTTPS endpoints.
func (b *SingBoxBackend) SpeedTest(ctx context.Context) (proto.SpeedTestResult, error) {
	return b.SpeedTestWithPolicy(ctx, nil)
}

func (b *SingBoxBackend) SpeedTestWithPolicy(ctx context.Context, policy *proto.SpeedProbePolicy) (proto.SpeedTestResult, error) {
	b.mu.Lock()
	socks := b.socks
	b.mu.Unlock()
	if socks == "" {
		return proto.SpeedTestResult{}, errors.New("sing-box is not running")
	}
	cfg := proto.SpeedProbePolicy{}
	if policy != nil {
		cfg = *policy
	}
	cfg.SetDefaults()
	if len(cfg.DownloadURLs) == 0 {
		cfg.DownloadURLs = []string{"https://speed.cloudflare.com/__down"}
	}
	if cfg.UploadURL == "" {
		cfg.UploadURL = "https://speed.cloudflare.com/__up"
	}

	dialer, err := proxy.SOCKS5("tcp", socks, nil, &net.Dialer{})
	if err != nil {
		return proto.SpeedTestResult{}, fmt.Errorf("socks5 dial: %w", err)
	}
	transport := &http.Transport{
		DialContext: func(_ context.Context, network, addr string) (net.Conn, error) {
			return dialer.Dial(network, addr)
		},
	}
	client := &http.Client{Transport: transport, Timeout: time.Duration(cfg.TimeoutSeconds) * time.Second}
	testStart := time.Now()
	result := proto.SpeedTestResult{TestedAt: testStart}

	for _, base := range cfg.DownloadURLs {
		if !strings.HasPrefix(base, "https://") {
			continue
		}
		u, parseErr := url.Parse(base)
		if parseErr != nil || u.Scheme != "https" {
			continue
		}
		q := u.Query()
		q.Set("bytes", strconv.FormatInt(cfg.SampleBytes, 10))
		u.RawQuery = q.Encode()
		req, reqErr := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
		if reqErr != nil {
			continue
		}
		resp, doErr := client.Do(req)
		if doErr != nil {
			result.Error = doErr.Error()
			continue
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			result.Error = fmt.Sprintf("download endpoint returned %s", resp.Status)
			resp.Body.Close()
			continue
		}
		start := time.Now()
		n, copyErr := io.CopyN(io.Discard, resp.Body, cfg.SampleBytes)
		resp.Body.Close()
		if copyErr != nil && !errors.Is(copyErr, io.EOF) && !errors.Is(copyErr, io.ErrUnexpectedEOF) {
			result.Error = copyErr.Error()
		}
		elapsed := time.Since(start).Seconds()
		if elapsed > 0 && n > 0 {
			result.DownloadBps = uint64(float64(n) / elapsed)
			result.DownloadMbps = float64(result.DownloadBps) * 8 / 1_000_000
			result.Error = ""
			break
		}
	}

	if strings.HasPrefix(cfg.UploadURL, "https://") {
		payload := bytes.NewReader(make([]byte, int(cfg.SampleBytes)))
		req, reqErr := http.NewRequestWithContext(ctx, http.MethodPost, cfg.UploadURL, payload)
		if reqErr == nil {
			req.Header.Set("Content-Type", "application/octet-stream")
			start := time.Now()
			resp, doErr := client.Do(req)
			if doErr == nil {
				_, _ = io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				if resp.StatusCode >= 200 && resp.StatusCode < 300 {
					elapsed := time.Since(start).Seconds()
					if elapsed > 0 {
						result.UploadBps = uint64(float64(cfg.SampleBytes) / elapsed)
						result.UploadMbps = float64(result.UploadBps) * 8 / 1_000_000
					}
				}
			}
		}
	}
	return result, nil
}
