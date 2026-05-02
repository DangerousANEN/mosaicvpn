// Package api implements the HTTP API exposed by the Mosaic daemon on the
// loopback interface. The same API is consumed by the CLI, the Tauri UI,
// and the embedded MCP server.
//
// Authentication is a shared bearer token written into the lockfile on
// daemon start. Clients read the lockfile, attach `Authorization: Bearer
// <token>`, and the daemon rejects any request without a matching token.
package api

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/DangerousANEN/mosaicvpn/internal/geoip"
	"github.com/DangerousANEN/mosaicvpn/internal/logx"
	"github.com/DangerousANEN/mosaicvpn/internal/paths"
	"github.com/DangerousANEN/mosaicvpn/internal/proto"
	"github.com/DangerousANEN/mosaicvpn/internal/state"
	"github.com/DangerousANEN/mosaicvpn/internal/store"
	"github.com/DangerousANEN/mosaicvpn/internal/subs"
)

// FetchResult is everything the fetcher managed to extract from one
// subscription HTTP response — the raw payload plus the server-declared
// format hint (Content-Type) and the Subscription-Userinfo header
// (traffic / expiry) if the remote set it.
type FetchResult struct {
	Body         []byte
	Format       string    // Content-Type, rarely useful except for data:// URLs
	TrafficUsed  uint64    // bytes
	TrafficTotal uint64    // bytes (0 = unlimited / not reported)
	ExpiresAt    time.Time // zero = not reported
}

// Fetcher is the function used to retrieve subscription payloads. The
// daemon wires in an HTTP-backed implementation; tests can supply an
// in-memory one.
type Fetcher func(ctx context.Context, url string) (FetchResult, error)

// Server bundles the daemon's HTTP API.
type Server struct {
	store   *store.Store
	mgr     *state.Manager
	token   string
	fetcher Fetcher

	mux *http.ServeMux

	// bgGeo serialises background geo-resolve passes triggered by
	// refresh / disconnect so a 1 000-server subscription doesn't
	// stack three concurrent ip-api batches against the same data.
	bgGeoMu sync.Mutex

	// egress wires the auxiliary-egress manager when the daemon owns
	// one. Nil when the API runs without an egress backend (mock,
	// tests). Set via SetEgressManager after construction so NewServer
	// stays compatible with the historic four-argument signature.
	egress EgressManager

	// onPrefsChanged, when non-nil, is invoked synchronously after a
	// successful PUT /v1/prefs. rc48 wires this to the MCP server so
	// it can rewrite mcp.json with the live permission/confirm value
	// (the MCP itself reads prefs live for auth gating, but agents
	// inspect the discovery file once on startup, so we keep them in
	// sync). Nil when no consumer wires it.
	onPrefsChanged func()
}

// EgressManager is the subset of internal/egress.Manager the API needs
// to drive auxiliary egress lifecycle.  Defined here as an interface to
// avoid an import cycle (internal/egress already imports
// internal/state, which imports internal/api in some test builds).
type EgressManager interface {
	Start(ctx context.Context, id string) error
	Stop(ctx context.Context, id string) error
	Status(id string) proto.EgressStatus
	ListStatus() map[string]proto.EgressStatus
}

// NewServer constructs an API server.
func NewServer(s *store.Store, mgr *state.Manager, fetcher Fetcher) *Server {
	if fetcher == nil {
		fetcher = HTTPFetcher(directHTTPClient(30 * time.Second))
	}
	srv := &Server{
		store:   s,
		mgr:     mgr,
		token:   newToken(),
		fetcher: fetcher,
		mux:     http.NewServeMux(),
	}
	srv.routes()
	return srv
}

// Token returns the secret bearer token. It is written into the lockfile
// so trusted local clients can authenticate.
func (s *Server) Token() string { return s.token }

// SetEgressManager wires an auxiliary-egress manager into the API
// server.  Called by mosaicd after both the API server and the
// egress.Manager are constructed (we can't pass it in NewServer
// because egress.Manager itself depends on the daemon data dir, which
// is computed alongside the API). Nil-safe — the egress endpoints
// reject requests with 503 when no manager is wired.
func (s *Server) SetEgressManager(m EgressManager) { s.egress = m }

// SetPrefsChangedHook registers a callback fired after every
// successful PUT /v1/prefs. Used by mosaicd to keep the MCP
// discovery file in sync with the live permission level so external
// agents see the same view of "connect / full / read" the renderer
// just saved.
func (s *Server) SetPrefsChangedHook(fn func()) { s.onPrefsChanged = fn }

// Handler returns the underlying http.Handler, including the CORS,
// auth, and logging middleware. CORS sits outermost so that preflight
// OPTIONS requests are answered without first being rejected by the
// bearer-token check; the renderer process (Tauri webview, browser dev
// server, etc.) lives at a different origin than 127.0.0.1:<random> and
// would otherwise have its preflight blocked.
func (s *Server) Handler() http.Handler {
	return s.corsMiddleware(s.authMiddleware(s.logMiddleware(s.mux)))
}

// Listen starts the HTTP server on 127.0.0.1:0 and returns its address.
// The server can be shut down via the returned function.
func (s *Server) Listen(ctx context.Context) (string, func(context.Context) error, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, err
	}
	httpSrv := &http.Server{
		Handler:           s.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		if err := httpSrv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logx.Error("api server crashed", "err", err)
		}
	}()
	addr := ln.Addr().String()
	logx.Info("api listening", "addr", addr)
	return addr, httpSrv.Shutdown, nil
}

func (s *Server) routes() {
	s.mux.HandleFunc("GET /v1/status", s.handleStatus)
	s.mux.HandleFunc("POST /v1/connect", s.handleConnect)
	s.mux.HandleFunc("POST /v1/disconnect", s.handleDisconnect)

	s.mux.HandleFunc("GET /v1/subscriptions", s.handleListSubs)
	s.mux.HandleFunc("POST /v1/subscriptions", s.handleAddSub)
	s.mux.HandleFunc("POST /v1/subscriptions/import", s.handleImportSub)
	s.mux.HandleFunc("PATCH /v1/subscriptions/{id}", s.handleUpdateSub)
	s.mux.HandleFunc("POST /v1/subscriptions/{id}/refresh", s.handleRefreshSub)
	s.mux.HandleFunc("DELETE /v1/subscriptions/{id}", s.handleDeleteSub)

	s.mux.HandleFunc("GET /v1/servers", s.handleListServers)
	s.mux.HandleFunc("POST /v1/servers/{id}/test", s.handleTestServer)
	s.mux.HandleFunc("POST /v1/servers/{id}/url-test", s.handleURLTestServer)
	s.mux.HandleFunc("POST /v1/servers/test-all", s.handleTestAll)

	s.mux.HandleFunc("GET /v1/rules", s.handleListRules)
	s.mux.HandleFunc("POST /v1/rules", s.handleAddRule)
	s.mux.HandleFunc("DELETE /v1/rules/{id}", s.handleDeleteRule)
	s.mux.HandleFunc("POST /v1/rules:reorder", s.handleReorderRules)

	s.mux.HandleFunc("GET /v1/prefs", s.handleGetPrefs)
	s.mux.HandleFunc("PUT /v1/prefs", s.handleSetPrefs)

	s.mux.HandleFunc("GET /v1/diag", s.handleDiag)
	s.mux.HandleFunc("GET /v1/events", s.handleEvents)
	s.mux.HandleFunc("POST /v1/speedtest", s.handleSpeedtest)

	// Auxiliary egress lifecycle (rc44).
	s.mux.HandleFunc("GET /v1/egresses", s.handleListEgresses)
	s.mux.HandleFunc("POST /v1/egresses", s.handleAddEgress)
	s.mux.HandleFunc("PATCH /v1/egresses/{id}", s.handleUpdateEgress)
	s.mux.HandleFunc("DELETE /v1/egresses/{id}", s.handleDeleteEgress)
	s.mux.HandleFunc("POST /v1/egresses/{id}/start", s.handleStartEgress)
	s.mux.HandleFunc("POST /v1/egresses/{id}/stop", s.handleStopEgress)
}

// ---------- handlers ------------------------------------------------------

func (s *Server) handleStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.mgr.Status())
}

func (s *Server) handleConnect(w http.ResponseWriter, r *http.Request) {
	var req proto.ConnectRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if err := s.mgr.Connect(r.Context(), req.ServerID); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.mgr.Status())
}

func (s *Server) handleDisconnect(w http.ResponseWriter, r *http.Request) {
	if err := s.mgr.Disconnect(r.Context()); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	// Re-attempt geo-resolution for any servers that came in while
	// the tunnel was up (DNS lookups were skipped to avoid poisoning
	// ResolvedIP through the proxy). Best-effort; runs in the
	// background so /v1/disconnect returns immediately.
	s.kickGeoResolve("")
	writeJSON(w, http.StatusOK, s.mgr.Status())
}

func (s *Server) handleListSubs(w http.ResponseWriter, _ *http.Request) {
	subs := s.store.Snapshot().Subscriptions
	if subs == nil {
		subs = []proto.Subscription{}
	}
	writeJSON(w, http.StatusOK, subs)
}

func (s *Server) handleAddSub(w http.ResponseWriter, r *http.Request) {
	var req proto.AddSubscriptionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if req.URL == "" {
		writeError(w, http.StatusBadRequest, "url required")
		return
	}
	name := req.Name
	if name == "" {
		name = req.URL
	}
	sub, err := s.store.AddOrUpdateSubscription(proto.Subscription{
		URL:                    req.URL,
		Name:                   name,
		Format:                 req.Format,
		AutoRefresh:            true,
		RefreshIntervalSeconds: 3600,
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := s.refresh(r.Context(), sub); err != nil {
		_ = s.store.MarkSubscriptionError(sub.ID, err.Error())
		writeError(w, http.StatusBadRequest, "fetch/parse failed: "+err.Error())
		return
	}
	s.kickGeoResolve(sub.ID)
	// reload after refresh
	for _, su := range s.store.Snapshot().Subscriptions {
		if su.ID == sub.ID {
			sub = su
			break
		}
	}
	writeJSON(w, http.StatusOK, sub)
}

// handleImportSub creates a subscription from an inline payload that
// the client already has in memory.  Used by the "Import from file"
// flow in the renderer for AmneziaWG `.conf`, AmneziaVPN `vpn://`
// tokens, sing-box JSON, Clash YAML, etc. — anything Detect knows.
//
// Imported subscriptions have an empty URL (there is no remote to
// re-poll) and AutoRefresh disabled; the parsed servers are stored
// once at import time.  The renderer's Refresh button is hidden for
// these and Edit can re-upload a new payload via this endpoint with
// the same ID semantics — but for now we treat each import as a new
// subscription, which keeps the handler trivially idempotent.
func (s *Server) handleImportSub(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name     string `json:"name"`
		Filename string `json:"filename"`
		Content  string `json:"content"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	payload := []byte(req.Content)
	if len(bytes.TrimSpace(payload)) == 0 {
		writeError(w, http.StatusBadRequest, "content required")
		return
	}
	name := strings.TrimSpace(req.Name)
	if name == "" {
		name = subs.SuggestNameFromFilename(req.Filename)
	}
	if name == "" {
		name = "Imported"
	}
	res, err := subs.ParseWithName("", payload, name)
	if err != nil {
		writeError(w, http.StatusBadRequest, "parse failed: "+err.Error())
		return
	}
	if res.Format == proto.FormatUnknown {
		writeError(w, http.StatusBadRequest, "unrecognised payload format")
		return
	}
	sub, err := s.store.AddOrUpdateSubscription(proto.Subscription{
		Name:                   name,
		URL:                    "",
		Format:                 res.Format,
		AutoRefresh:            false,
		RefreshIntervalSeconds: 0,
		LastFetched:            time.Now().UTC(),
		ServerCount:            len(res.Servers),
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// Re-key parsed servers under the assigned subscription ID so
	// Server.SubscriptionID matches Subscription.ID for the
	// renderer's join.
	rekeyed, err := subs.ParseWithName(sub.ID, payload, name)
	if err != nil {
		_ = s.store.MarkSubscriptionError(sub.ID, err.Error())
		writeError(w, http.StatusBadRequest, "reparse failed: "+err.Error())
		return
	}
	if err := s.store.ReplaceServersFor(sub.ID, rekeyed.Servers); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.kickGeoResolve(sub.ID)
	for _, su := range s.store.Snapshot().Subscriptions {
		if su.ID == sub.ID {
			sub = su
			break
		}
	}
	writeJSON(w, http.StatusOK, sub)
}

func (s *Server) handleRefreshSub(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var target *proto.Subscription
	for _, su := range s.store.Snapshot().Subscriptions {
		if su.ID == id {
			cp := su
			target = &cp
			break
		}
	}
	if target == nil {
		writeError(w, http.StatusNotFound, "subscription not found")
		return
	}
	if err := s.refresh(r.Context(), *target); err != nil {
		_ = s.store.MarkSubscriptionError(id, err.Error())
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	s.kickGeoResolve(id)
	for _, su := range s.store.Snapshot().Subscriptions {
		if su.ID == id {
			writeJSON(w, http.StatusOK, su)
			return
		}
	}
	writeJSON(w, http.StatusOK, target)
}

// handleUpdateSub mutates name/url on an existing subscription. The
// renderer wires this to the Servers-screen Edit modal. After a URL
// change we automatically run /refresh so the server list reflects
// the new feed without forcing the user to click Refresh manually.
func (s *Server) handleUpdateSub(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req struct {
		Name string `json:"name"`
		URL  string `json:"url"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	updated, err := s.store.UpdateSubscriptionFields(id, strings.TrimSpace(req.Name), strings.TrimSpace(req.URL))
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	if strings.TrimSpace(req.URL) != "" {
		// URL changed → refetch so /v1/servers and the map pin
		// set immediately reflect the new feed. Failure here is
		// non-fatal; we still surface the renamed/repointed
		// record so the UI can show the user what was saved.
		if err := s.refresh(r.Context(), updated); err != nil {
			_ = s.store.MarkSubscriptionError(id, err.Error())
		} else {
			s.kickGeoResolve(id)
			for _, su := range s.store.Snapshot().Subscriptions {
				if su.ID == id {
					updated = su
					break
				}
			}
		}
	}
	writeJSON(w, http.StatusOK, updated)
}

func (s *Server) handleDeleteSub(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.store.DeleteSubscription(id); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleListServers(w http.ResponseWriter, r *http.Request) {
	snap := s.store.Snapshot()
	subID := r.URL.Query().Get("subscription_id")
	out := snap.Servers
	if subID != "" {
		out = out[:0]
		for _, sv := range snap.Servers {
			if sv.SubscriptionID == subID {
				out = append(out, sv)
			}
		}
	}
	if out == nil {
		// JSON-encode an empty slice as `[]` rather than `null` so the
		// renderer can iterate it unconditionally.
		out = []proto.Server{}
	}
	writeJSON(w, http.StatusOK, out)
}

// probeServer performs a TCP dial to addr:port and returns the round-trip
// time in milliseconds, or a negative number plus an error message on
// failure.
//
// If dialIP is non-empty, the TCP dial is sent to dialIP:port directly
// instead of resolving addr — this bypasses the local system resolver,
// which on Windows is the most common reason latencies collapse to
// 1–2ms (the resolver returns 127.0.0.1 / a tunnel-exit IP, and the
// dial terminates locally).
//
// Sub-millisecond RTTs are reported with their true microsecond value
// formatted as ms (rounded), and never floored to 1 — a real 0.4ms
// reading is itself a strong signal that the dial never left the host.
func probeServer(ctx context.Context, addr string, port int, dialIP string, timeout time.Duration) (int, string) {
	return probeServerNet(ctx, "tcp", addr, port, dialIP, timeout)
}

// probeServerNet is the network-aware variant.  TCP dials open a SYN
// and read the SYN-ACK; the round-trip is the RTT.  UDP "dials"
// don't actually exchange anything in user space — net.Dial just
// connects the socket so kernel ICMP errors get routed back to us.
// For UDP we send one zero byte then attempt a bounded read:
//
//   - read returns OK / EOF      → host responded → RTT = elapsed
//   - read fails with ECONNREFUSED → kernel saw an ICMP unreachable
//     → port closed → fail
//   - read times out             → host swallowed the byte (typical
//     for hysteria2 / wireguard / amneziawg, which never reply to
//     unauthenticated payloads) → return timeout as RTT and a "udp"
//     tag in the message so the caller can colour the cell
//     accordingly.
//
// This is a best-effort heuristic — UDP probing is fundamentally
// ambiguous — but it's vastly better than the previous behaviour of
// reporting every UDP-only server as TCP-unreachable.
func probeServerNet(ctx context.Context, network, addr string, port int, dialIP string, timeout time.Duration) (int, string) {
	if port <= 0 {
		return -1, "invalid port"
	}
	if network == "" {
		network = "tcp"
	}
	dialHost := dialIP
	if dialHost == "" {
		dialHost = addr
	}
	target := net.JoinHostPort(dialHost, fmt.Sprint(port))
	dialer := net.Dialer{Timeout: timeout}
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	t0 := time.Now()
	conn, err := dialer.DialContext(cctx, network, target)
	if err != nil {
		logx.Debug("probe dial failed", "addr", addr, "port", port, "dial_ip", dialIP, "net", network, "err", err)
		return -1, err.Error()
	}
	if network == "udp" {
		// One-byte poke; QUIC / WireGuard servers ignore it but will
		// still ICMP-reply if the port is closed.
		_ = conn.SetDeadline(time.Now().Add(timeout))
		_, _ = conn.Write([]byte{0})
		buf := make([]byte, 64)
		_, rerr := conn.Read(buf)
		elapsed := time.Since(t0)
		remote := conn.RemoteAddr().String()
		_ = conn.Close()
		switch {
		case rerr == nil:
			rtt := int((elapsed.Microseconds() + 500) / 1000)
			if rtt < 1 {
				rtt = 1
			}
			logx.Debug("udp probe replied", "addr", addr, "port", port, "remote", remote, "rtt_ms", rtt)
			return rtt, ""
		case isConnRefused(rerr):
			logx.Debug("udp probe refused (icmp)", "addr", addr, "port", port, "err", rerr)
			return -1, "udp closed: " + rerr.Error()
		default:
			// Timeout / silence is the normal answer for QUIC / WG.
			// Report the timeout itself as RTT so the UI can render
			// "alive but silent" rather than an unreachable cell.
			rtt := int(timeout / time.Millisecond)
			logx.Debug("udp probe silent (presumed alive)", "addr", addr, "port", port, "rtt_ms", rtt, "err", rerr)
			return rtt, ""
		}
	}
	elapsed := time.Since(t0)
	remote := conn.RemoteAddr().String()
	_ = conn.Close()
	us := elapsed.Microseconds()
	rtt := int((us + 500) / 1000)
	if rtt < 1 {
		rtt = 1
	}
	logx.Debug("probe ok", "addr", addr, "port", port, "dial_ip", dialIP, "remote", remote, "rtt_us", us, "rtt_ms", rtt)
	if suspiciousRemote(remote) {
		logx.Warn("probe remote looks local/hijacked", "addr", addr, "port", port, "remote", remote, "rtt_us", us)
	}
	return rtt, ""
}

// isConnRefused returns true when err originates in an ICMP
// unreachable received by the kernel for a connected UDP socket.
// The platform-specific spelling differs (ECONNREFUSED on POSIX,
// WSAECONNREFUSED on Windows); both surface as `connection refused`
// in the formatted message so a substring match is sufficient.
func isConnRefused(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "connection refused") ||
		strings.Contains(msg, "connection was refused")
}

// probeNetworkFor picks the right probe network for a server's
// protocol.  hy2/wireguard/amneziawg are UDP-only, the rest are TCP.
func probeNetworkFor(p proto.Protocol) string {
	switch p {
	case proto.ProtoHysteria2, proto.ProtoAmneziaWG:
		return "udp"
	}
	return "tcp"
}

// suspiciousRemote reports whether the remote endpoint of a probe is a
// loopback or RFC1918 address — a strong hint that the system DNS
// resolved the target to a local interface, or that an active tunnel
// is rewriting destinations to its own exit. We only log a warning;
// the latency reading is still returned because the dial did succeed.
func suspiciousRemote(remote string) bool {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified()
}

// resolveServerGeo computes the best-guess geographic metadata for
// srv and persists it through st. The priority is:
//
//  1. If the server name contains an ISO-2 country prefix (e.g.
//     "DE-VLESS-WS"), trust that for Country and place the pin at the
//     country centroid — ip-api.com is then only used to refine
//     the city / lat / lon when its country agrees.
//  2. Otherwise fall back to ip-api.com unconditionally.
//
// Already-populated lat/lon are not overwritten — once a server has
// coordinates we keep them across re-tests.
func resolveServerGeo(ctx context.Context, st *store.Store, srv proto.Server) {
	if srv.Lat != 0 || srv.Lon != 0 {
		return
	}
	hint := geoip.IsoFromName(srv.Name)
	geo, err := geoip.Lookup(ctx, srv.Address)
	switch {
	case err == nil && hint != "" && geo.Country == hint:
		// Both agree → use the precise lat/lon from ip-api.
		_ = st.RecordServerGeo(srv.ID, geo.City, geo.Country, geo.Lat, geo.Lon)
	case hint != "":
		// Hint wins. Drop a centroid pin so the map shows the right
		// country even if ip-api.com pointed at the ASN owner.
		c, ok := geoip.CountryCentroid[hint]
		if !ok {
			return
		}
		_ = st.RecordServerGeo(srv.ID, "", hint, c[0], c[1])
	case err == nil:
		_ = st.RecordServerGeo(srv.ID, geo.City, geo.Country, geo.Lat, geo.Lon)
	}
}

// resolveServerGeoBatch resolves geo metadata for every server in
// targets that doesn't already have lat/lon, using ip-api.com's batch
// endpoint in chunks of 100. The country-name hint (IsoFromName)
// still wins over a disagreeing GeoIP result so a "DE-VLESS" server
// hosted on a US-owned ASN still drops at the German centroid. On a
// 1 000-server subscription this is ~10 batch HTTP calls, well within
// the free-tier 15 req/min budget.
func resolveServerGeoBatch(ctx context.Context, st *store.Store, targets []proto.Server) {
	type pending struct {
		srv  proto.Server
		hint string
	}
	// Re-snap servers so we see ResolvedIP that phase-1 just wrote;
	// without this the batch lookup would target the bare hostname,
	// re-paying the DNS round-trip we already spent.
	snap := st.Snapshot()
	byID := map[string]proto.Server{}
	for _, sv := range snap.Servers {
		byID[sv.ID] = sv
	}
	// Pre-compute the work list so we can run the DNS-fallback step
	// in parallel. Sequential ResolveHost on a 1 000-server feed is
	// the regression that hid pins entirely in rc24.
	type slot struct {
		idx  int
		srv  proto.Server
		hint string
	}
	work := make([]slot, 0, len(targets))
	for _, sv := range targets {
		fresh, ok := byID[sv.ID]
		if !ok {
			fresh = sv
		}
		if fresh.Lat != 0 || fresh.Lon != 0 {
			continue
		}
		work = append(work, slot{
			idx:  len(work),
			srv:  fresh,
			hint: geoip.IsoFromName(fresh.Name),
		})
	}
	hosts := make([]string, len(work))
	for i, s := range work {
		if s.srv.ResolvedIP != "" {
			hosts[i] = s.srv.ResolvedIP
		}
	}
	// Parallel ResolveHost for any slot that didn't already carry an
	// IP. ip-api.com's batch endpoint silently returns empty rows
	// for bare hostnames, so we MUST hand it IPs to keep the second-
	// subscription pin gap from rc23 fixed.
	const dnsConcurrency = 16
	dnsSem := make(chan struct{}, dnsConcurrency)
	var dnsWG sync.WaitGroup
	for i := range work {
		if hosts[i] != "" {
			continue
		}
		dnsWG.Add(1)
		dnsSem <- struct{}{}
		go func(i int) {
			defer dnsWG.Done()
			defer func() { <-dnsSem }()
			s := work[i]
			if ip := geoip.ResolveHost(ctx, s.srv.Address); ip != "" {
				hosts[i] = ip
				_ = st.RecordServerResolved(s.srv.ID, ip)
				return
			}
			// Last-ditch: hand the bare hostname to ip-api anyway.
			// Some entries (e.g. DNS-over-HTTPS resolved later) still
			// produce a useful row.
			hosts[i] = s.srv.Address
		}(i)
	}
	dnsWG.Wait()
	queue := make([]pending, len(work))
	for i, s := range work {
		queue[i] = pending{srv: s.srv, hint: s.hint}
	}
	if len(queue) == 0 {
		return
	}
	const chunkSize = 100
	for start := 0; start < len(queue); start += chunkSize {
		end := start + chunkSize
		if end > len(queue) {
			end = len(queue)
		}
		results, err := geoip.LookupBatch(ctx, hosts[start:end])
		if err != nil {
			logx.Warn("geoip batch failed", "err", err, "from", start, "to", end)
			// Fall back to per-host single lookups for this chunk —
			// slower, but at least the user doesn't lose every pin
			// when one batch call hiccups.
			for i := start; i < end; i++ {
				p := queue[i]
				geo, lerr := geoip.Lookup(ctx, hosts[i])
				if lerr != nil {
					applyGeoHint(st, p.srv, p.hint, geoip.Result{}, false)
					continue
				}
				applyGeoHint(st, p.srv, p.hint, geo, true)
			}
			continue
		}
		for i, r := range results {
			p := queue[start+i]
			ok := r.Err == "" && (r.Result.Lat != 0 || r.Result.Lon != 0 || r.Result.Country != "")
			applyGeoHint(st, p.srv, p.hint, r.Result, ok)
		}
	}
}

// applyGeoHint persists the best of (ip-api result, country-name hint)
// onto the server, mirroring the priority used by resolveServerGeo.
func applyGeoHint(st *store.Store, srv proto.Server, hint string, geo geoip.Result, geoOK bool) {
	switch {
	case geoOK && hint != "" && geo.Country == hint:
		_ = st.RecordServerGeo(srv.ID, geo.City, geo.Country, geo.Lat, geo.Lon)
	case hint != "":
		c, ok := geoip.CountryCentroid[hint]
		if !ok {
			if geoOK {
				_ = st.RecordServerGeo(srv.ID, geo.City, geo.Country, geo.Lat, geo.Lon)
			}
			return
		}
		_ = st.RecordServerGeo(srv.ID, "", hint, c[0], c[1])
	case geoOK:
		_ = st.RecordServerGeo(srv.ID, geo.City, geo.Country, geo.Lat, geo.Lon)
	}
}

// handleTestServer probes a single server identified by path id and
// returns the updated server record.
func (s *Server) handleTestServer(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	srv, ok := s.store.FindServer(id)
	if !ok {
		writeError(w, http.StatusNotFound, "server not found")
		return
	}
	connected := s.mgr.Status().State == proto.StateConnected
	// Resolve first so the probe dial bypasses the system resolver
	// (which on Windows can be hijacked by an active tunnel and is the
	// suspected root cause of 1–2ms readings on every server). Skip
	// while connected — any DNS lookup right now would go through the
	// tunnel and poison ResolvedIP with a tunnel-exit IP.
	dialIP := ""
	if !connected {
		if ip := geoip.ResolveHost(r.Context(), srv.Address); ip != "" {
			_ = s.store.RecordServerResolved(id, ip)
			dialIP = ip
		}
	} else {
		dialIP = srv.ResolvedIP
	}
	ms, errMsg := probeServerNet(r.Context(), probeNetworkFor(srv.Protocol), srv.Address, srv.Port, dialIP, 5*time.Second)
	if err := s.store.RecordServerProbe(id, ms, errMsg); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !connected {
		resolveServerGeo(r.Context(), s.store, srv)
	}
	updated, _ := s.store.FindServer(id)
	writeJSON(w, http.StatusOK, updated)
}

// handleURLTestServer runs a true VPN-access probe by spinning up an
// ephemeral sing-box, opening a SOCKS port against the requested
// server's outbound, and fetching https://www.gstatic.com/generate_204
// through it. A 204 result is positive proof that the server actually
// proxies clean HTTPS traffic — unlike the TCP probe which only
// confirms the remote listener answered. Refuses while a real Connect
// session is active so two sing-boxes don't fight for ports.
func (s *Server) handleURLTestServer(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	srv, ok := s.store.FindServer(id)
	if !ok {
		writeError(w, http.StatusNotFound, "server not found")
		return
	}
	if s.mgr.Status().State == proto.StateConnected {
		writeError(w, http.StatusConflict, "url-test unavailable while connected; disconnect first")
		return
	}
	dataDir := paths.DataDir()
	prefs := s.store.Snapshot().Prefs
	res := state.URLTestServer(r.Context(), state.LocateSingBox(), dataDir, prefs.URLTestEndpoint, prefs, srv, 12*time.Second)
	// Persist the result so the SubscriptionDetail Verify column
	// can surface the last-known state without re-running.  Best-
	// effort: a write failure here only affects display; the live
	// response below still carries the verdict.
	if err := s.store.RecordURLTest(id, res.RTTMS, res.Status, res.Error); err != nil {
		logx.Warn("RecordURLTest failed", "server", id, "err", err.Error())
	}
	writeJSON(w, http.StatusOK, res)
}

// handleTestAll probes every server (or all servers under a single
// subscription if subscription_id is provided) in parallel and returns
// the refreshed list. GeoIP resolution uses ip-api.com's /batch
// endpoint (up to 100 entries per request) so 1 000-server
// subscriptions don't burn through the per-IP rate limit; per-server
// TCP probes still run in parallel.
func (s *Server) handleTestAll(w http.ResponseWriter, r *http.Request) {
	subID := r.URL.Query().Get("subscription_id")
	snap := s.store.Snapshot()
	targets := make([]proto.Server, 0, len(snap.Servers))
	for _, sv := range snap.Servers {
		if subID == "" || sv.SubscriptionID == subID {
			targets = append(targets, sv)
		}
	}
	connected := s.mgr.Status().State == proto.StateConnected
	if connected {
		logx.Warn("test-all while connected: DNS lookups skipped to avoid poisoning ResolvedIP via tunnel")
	}
	// Phase 1: DNS resolve + TCP probe in parallel. The batch GeoIP
	// pass that follows wants ResolvedIP populated, so this round must
	// finish first.
	const concurrency = 16
	sem := make(chan struct{}, concurrency)
	done := make(chan struct{}, len(targets))
	for _, sv := range targets {
		sv := sv
		sem <- struct{}{}
		go func() {
			defer func() { <-sem; done <- struct{}{} }()
			dialIP := ""
			if !connected {
				if ip := geoip.ResolveHost(r.Context(), sv.Address); ip != "" {
					_ = s.store.RecordServerResolved(sv.ID, ip)
					dialIP = ip
				}
			} else {
				dialIP = sv.ResolvedIP
			}
			ms, errMsg := probeServerNet(r.Context(), probeNetworkFor(sv.Protocol), sv.Address, sv.Port, dialIP, 4*time.Second)
			_ = s.store.RecordServerProbe(sv.ID, ms, errMsg)
		}()
	}
	for range targets {
		<-done
	}
	// Phase 2: batch GeoIP. Skip while connected so we don't accidentally
	// resolve through the live tunnel.
	if !connected {
		resolveServerGeoBatch(r.Context(), s.store, targets)
	}
	out := s.store.Snapshot().Servers
	if subID != "" {
		filtered := out[:0]
		for _, sv := range out {
			if sv.SubscriptionID == subID {
				filtered = append(filtered, sv)
			}
		}
		out = filtered
	}
	if out == nil {
		out = []proto.Server{}
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleListRules(w http.ResponseWriter, _ *http.Request) {
	rules := s.store.Snapshot().Rules
	if rules == nil {
		rules = []proto.Rule{}
	}
	writeJSON(w, http.StatusOK, rules)
}

func (s *Server) handleAddRule(w http.ResponseWriter, r *http.Request) {
	var rule proto.Rule
	if err := json.NewDecoder(r.Body).Decode(&rule); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if rule.Action == "" {
		writeError(w, http.StatusBadRequest, "action required")
		return
	}
	saved, err := s.store.AddRule(rule)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, saved)
}

func (s *Server) handleDeleteRule(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.store.DeleteRule(id); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleReorderRules(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IDs []string `json:"ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	snap := s.store.Snapshot()
	byID := map[string]proto.Rule{}
	for _, r := range snap.Rules {
		byID[r.ID] = r
	}
	out := make([]proto.Rule, 0, len(req.IDs))
	for i, id := range req.IDs {
		r, ok := byID[id]
		if !ok {
			writeError(w, http.StatusBadRequest, "unknown rule id: "+id)
			return
		}
		r.Priority = i + 1
		out = append(out, r)
	}
	if err := s.store.ReplaceRules(out); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleGetPrefs(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.store.Snapshot().Prefs)
}

func (s *Server) handleSetPrefs(w http.ResponseWriter, r *http.Request) {
	var p store.Prefs
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if err := s.store.SetPrefs(p); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.mgr.SetTunnelPrefs(p.TunnelMode, p.KillSwitch)
	if s.onPrefsChanged != nil {
		s.onPrefsChanged()
	}
	writeJSON(w, http.StatusOK, p)
}

func (s *Server) handleSpeedtest(w http.ResponseWriter, r *http.Request) {
	type req struct {
		URL string `json:"url"`
	}
	var body req
	if r.ContentLength > 0 {
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
	}
	// Speedtest can take ~10-30 s; give it a generous deadline that
	// is independent of the (typically short) HTTP request timeout
	// the API server runs with.
	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()
	res, err := s.mgr.Speedtest(ctx, body.URL)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) handleDiag(w http.ResponseWriter, _ *http.Request) {
	snap := s.store.Snapshot()
	writeJSON(w, http.StatusOK, proto.DiagReport{
		GeneratedAt:   time.Now().UTC(),
		DaemonVersion: s.mgr.Version(),
		Status:        s.mgr.Status(),
		Subscriptions: snap.Subscriptions,
		ServerCount:   len(snap.Servers),
		RuleCount:     len(snap.Rules),
	})
}

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)

	ch, cancel := s.mgr.Subscribe()
	defer cancel()

	// Send the current state immediately so clients have something.
	if err := writeSSE(w, "status", s.mgr.Status()); err != nil {
		return
	}
	flusher.Flush()

	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case st, ok := <-ch:
			if !ok {
				return
			}
			if err := writeSSE(w, "status", st); err != nil {
				return
			}
			flusher.Flush()
		case <-heartbeat.C:
			fmt.Fprintf(w, ": heartbeat\n\n")
			flusher.Flush()
		}
	}
}

// ---------- helpers -------------------------------------------------------

// kickGeoResolve schedules a background geo-resolve pass for either a
// specific subscription (subID != "") or every server still missing
// lat/lon. It exits early if the daemon is currently connected — DNS
// lookups would otherwise be captured by the live tunnel and produce
// useless ResolvedIP entries (this is the same condition that gates
// the connected branch in handleTestAll). The pass is serialised by
// bgGeoMu so a quick succession of /v1/subscriptions POSTs (the rc24
// "added 1 000 then 9 servers, no pins" report) doesn't stack three
// concurrent ip-api batches at the same data.
func (s *Server) kickGeoResolve(subID string) {
	if s.mgr.Status().State == proto.StateConnected {
		return
	}
	go func() {
		s.bgGeoMu.Lock()
		defer s.bgGeoMu.Unlock()
		// Re-check connection state inside the lock so a Connect
		// that races a refresh doesn't push DNS through the tunnel.
		if s.mgr.Status().State == proto.StateConnected {
			return
		}
		// Cap the whole pass at ~90 s so a hung ip-api endpoint or
		// 1 000-server DNS storm can't keep this goroutine alive
		// forever. Background ctx — the originating request is
		// long gone.
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		snap := s.store.Snapshot()
		targets := make([]proto.Server, 0, len(snap.Servers))
		for _, sv := range snap.Servers {
			if subID != "" && sv.SubscriptionID != subID {
				continue
			}
			if sv.Lat != 0 || sv.Lon != 0 {
				continue
			}
			targets = append(targets, sv)
		}
		if len(targets) == 0 {
			return
		}
		logx.Info("background geo-resolve starting", "sub", subID, "servers", len(targets))
		resolveServerGeoBatch(ctx, s.store, targets)
		logx.Info("background geo-resolve finished", "sub", subID, "servers", len(targets))
	}()
}

// Refresh is the exported refresh helper used by MCP tools. It re-fetches
// a subscription and replaces its server list. Callers should normally
// follow up with KickGeoResolve(sub.ID) to backfill geo info.
func (s *Server) Refresh(ctx context.Context, sub proto.Subscription) error {
	return s.refresh(ctx, sub)
}

// KickGeoResolve schedules a background geo-resolve pass for the given
// subscription (empty string = all). Exported for MCP / CLI use.
func (s *Server) KickGeoResolve(subID string) { s.kickGeoResolve(subID) }

// ---------- egress handlers (rc44) -----------------------------------

// egressDTO bundles the persisted config with live runtime state so a
// single GET response is enough for the renderer to draw the row.
type egressDTO struct {
	proto.EgressConfig
	Status proto.EgressStatus `json:"status"`
}

func (s *Server) handleListEgresses(w http.ResponseWriter, _ *http.Request) {
	cfgs := s.store.Snapshot().Egresses
	if cfgs == nil {
		cfgs = []proto.EgressConfig{}
	}
	statuses := map[string]proto.EgressStatus{}
	if s.egress != nil {
		statuses = s.egress.ListStatus()
	}
	out := make([]egressDTO, 0, len(cfgs))
	for _, c := range cfgs {
		out = append(out, egressDTO{EgressConfig: c, Status: statuses[c.ID]})
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAddEgress(w http.ResponseWriter, r *http.Request) {
	var req proto.EgressConfig
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if req.ServerID == "" {
		writeError(w, http.StatusBadRequest, "server_id required")
		return
	}
	if req.Port <= 0 || req.Port > 65535 {
		writeError(w, http.StatusBadRequest, "port must be 1..65535")
		return
	}
	if _, ok := s.store.FindServer(req.ServerID); !ok {
		writeError(w, http.StatusNotFound, "server not found")
		return
	}
	saved, err := s.store.AddEgress(req)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, saved)
}

func (s *Server) handleUpdateEgress(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req proto.EgressConfig
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	req.ID = id
	if req.ServerID == "" {
		writeError(w, http.StatusBadRequest, "server_id required")
		return
	}
	if req.Port <= 0 || req.Port > 65535 {
		writeError(w, http.StatusBadRequest, "port must be 1..65535")
		return
	}
	saved, err := s.store.UpdateEgress(req)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	// If running, restart so the new config takes effect.
	if s.egress != nil {
		st := s.egress.Status(id)
		if st.Running {
			_ = s.egress.Stop(r.Context(), id)
			if err := s.egress.Start(r.Context(), id); err != nil {
				writeError(w, http.StatusInternalServerError, "restart: "+err.Error())
				return
			}
		}
	}
	writeJSON(w, http.StatusOK, saved)
}

func (s *Server) handleDeleteEgress(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if s.egress != nil {
		_ = s.egress.Stop(r.Context(), id)
	}
	if err := s.store.DeleteEgress(id); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleStartEgress(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if s.egress == nil {
		writeError(w, http.StatusServiceUnavailable, "egress manager not wired")
		return
	}
	if err := s.egress.Start(r.Context(), id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.egress.Status(id))
}

func (s *Server) handleStopEgress(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if s.egress == nil {
		writeError(w, http.StatusServiceUnavailable, "egress manager not wired")
		return
	}
	if err := s.egress.Stop(r.Context(), id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.egress.Status(id))
}

// URLTestServer runs a Verify (URL test) probe through serverID,
// persists the result on the server record, and returns any error.
// This is the MCP-facing wrapper around the same sing-box probe the
// /v1/servers/{id}/url-test handler uses.
func (s *Server) URLTestServer(ctx context.Context, serverID string) error {
	var srv *proto.Server
	for _, sv := range s.store.Snapshot().Servers {
		if sv.ID == serverID {
			cp := sv
			srv = &cp
			break
		}
	}
	if srv == nil {
		return fmt.Errorf("server %s not found", serverID)
	}
	prefs := s.store.Snapshot().Prefs
	dataDir := paths.DataDir()
	res := state.URLTestServer(ctx, state.LocateSingBox(), dataDir, prefs.URLTestEndpoint, prefs, *srv, 12*time.Second)
	return s.store.RecordURLTest(serverID, res.RTTMS, res.Status, res.Error)
}

func (s *Server) refresh(ctx context.Context, sub proto.Subscription) error {
	fr, err := s.fetcher(ctx, sub.URL)
	if err != nil {
		return fmt.Errorf("fetch: %w", err)
	}
	var res subs.Result
	if sub.Format != "" && sub.Format != proto.FormatUnknown {
		res, err = subs.ParseAs(sub.ID, fr.Body, sub.Format)
	} else {
		res, err = subs.Parse(sub.ID, fr.Body)
	}
	if err != nil {
		return fmt.Errorf("parse: %w", err)
	}
	sub.Format = res.Format
	sub.ServerCount = len(res.Servers)
	sub.LastFetched = time.Now().UTC()
	sub.LastError = ""
	// Only overwrite traffic / expiry fields when the remote actually
	// reported them this fetch. A remote that drops the header between
	// fetches keeps the last known values visible.
	if fr.TrafficTotal != 0 || fr.TrafficUsed != 0 {
		sub.TrafficUsed = fr.TrafficUsed
		sub.TrafficTotal = fr.TrafficTotal
	}
	if !fr.ExpiresAt.IsZero() {
		sub.ExpiresAt = fr.ExpiresAt
	}
	if _, err := s.store.AddOrUpdateSubscription(sub); err != nil {
		return err
	}
	return s.store.ReplaceServersFor(sub.ID, res.Servers)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func writeSSE(w http.ResponseWriter, event string, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if event != "" {
		fmt.Fprintf(w, "event: %s\n", event)
	}
	fmt.Fprintf(w, "data: %s\n\n", data)
	return nil
}

func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Preflight requests carry no Authorization header by design;
		// they are answered by corsMiddleware and never reach here, but
		// be defensive in case the chain is reordered in the future.
		if r.Method == http.MethodOptions {
			next.ServeHTTP(w, r)
			return
		}
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			writeError(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		got := strings.TrimPrefix(auth, "Bearer ")
		if subtle.ConstantTimeCompare([]byte(got), []byte(s.token)) != 1 {
			writeError(w, http.StatusUnauthorized, "bad token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// corsMiddleware permits the renderer (Tauri webview or `vite dev` at
// http://localhost:1420) to call the loopback API. Security is provided
// by the bearer token in the lockfile and the fact that the listener is
// bound to 127.0.0.1 — the broad Allow-Origin is acceptable for that
// model. Preflight OPTIONS requests short-circuit here with 204.
func (s *Server) corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		setCORSHeaders(w, r)
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func setCORSHeaders(w http.ResponseWriter, r *http.Request) {
	origin := r.Header.Get("Origin")
	if origin == "" {
		origin = "*"
	}
	h := w.Header()
	h.Set("Access-Control-Allow-Origin", origin)
	h.Set("Vary", "Origin")
	h.Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
	h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Accept, Cache-Control")
	h.Set("Access-Control-Expose-Headers", "Content-Type")
	h.Set("Access-Control-Max-Age", "600")
}

func (s *Server) logMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		logx.Debug("api request", "method", r.Method, "path", r.URL.Path, "took", time.Since(start))
	})
}

func newToken() string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		// Crypto/rand failures are exceptional; pick something that's still
		// long enough to be useful for a local-only API.
		return fmt.Sprintf("fallback-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b[:])
}

// directHTTPClient builds an HTTP client that explicitly bypasses any
// system / environment proxy and resolves names through the same
// public-DNS resolvers as geoip.ResolveHost (1.1.1.1 → 8.8.8.8 →
// system fallback). This is what mosaicd uses to fetch subscriptions:
// reaching a sub.txt URL must NOT route through sing-box's loopback
// SOCKS at 127.0.0.1:2080 even when an active VPN tunnel is up, and
// must NOT depend on whatever the OS thinks 'sub.example.com' resolves
// to (the same system-DNS hijack rc13 worked around for probes).
func directHTTPClient(timeout time.Duration) *http.Client {
	dialer := &net.Dialer{
		Timeout:   10 * time.Second,
		KeepAlive: 30 * time.Second,
		Resolver:  geoip.DirectResolver(),
	}
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			// Explicitly nil — do NOT honour HTTP_PROXY / HTTPS_PROXY
			// env vars or the Windows system proxy. Otherwise mosaicd
			// can end up sending its own subscription fetches through
			// the sing-box loopback SOCKS we're supposedly proxying for.
			Proxy:                 nil,
			DialContext:           dialer.DialContext,
			ForceAttemptHTTP2:     true,
			MaxIdleConns:          16,
			IdleConnTimeout:       60 * time.Second,
			TLSHandshakeTimeout:   10 * time.Second,
			ExpectContinueTimeout: 1 * time.Second,
		},
	}
}

// HTTPFetcher returns a Fetcher that uses the supplied HTTP client.
// Pass nil to get a sensible direct-out-to-the-internet client — see
// directHTTPClient for why DefaultClient is the wrong default.
//
// rc28 — also accepts `data:` URLs (RFC 2397) so the renderer's
// drag-and-drop importer can feed local files straight through
// addSubscription without needing a separate upload endpoint. The
// scheme is detected up-front; only base64 data URLs are supported
// — that's what the renderer always emits.
func HTTPFetcher(client *http.Client) Fetcher {
	if client == nil {
		client = directHTTPClient(30 * time.Second)
	}
	return func(ctx context.Context, url string) (FetchResult, error) {
		if strings.HasPrefix(url, "data:") {
			body, mime, err := decodeDataURL(url)
			return FetchResult{Body: body, Format: mime}, err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return FetchResult{}, err
		}
		req.Header.Set("User-Agent", "Mosaic/0.1")
		resp, err := client.Do(req)
		if err != nil {
			return FetchResult{}, err
		}
		defer resp.Body.Close()
		if resp.StatusCode/100 != 2 {
			return FetchResult{}, fmt.Errorf("http %s", resp.Status)
		}
		body, err := readAllLimited(resp.Body, 16<<20) // 16 MiB cap
		if err != nil {
			return FetchResult{}, err
		}
		up, down, total, exp := parseSubscriptionUserinfo(resp.Header.Get("Subscription-Userinfo"))
		return FetchResult{
			Body:         body,
			Format:       resp.Header.Get("Content-Type"),
			TrafficUsed:  up + down,
			TrafficTotal: total,
			ExpiresAt:    exp,
		}, nil
	}
}

// parseSubscriptionUserinfo parses the de-facto-standard panel header:
//
//	Subscription-Userinfo: upload=0; download=1234567890; total=107374182400; expire=1767225600
//
// Upload/download/total are bytes (uint64), expire is Unix seconds.
// Panels that don't set the header send an empty string → all zeros.
// Returns (upload, download, total, expiresAt). A zero `expire` value is
// normalised to a zero time.Time so callers can check `IsZero()`.
func parseSubscriptionUserinfo(header string) (uint64, uint64, uint64, time.Time) {
	if header == "" {
		return 0, 0, 0, time.Time{}
	}
	var up, down, total uint64
	var exp time.Time
	for _, part := range strings.Split(header, ";") {
		kv := strings.SplitN(strings.TrimSpace(part), "=", 2)
		if len(kv) != 2 {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(kv[0]))
		val := strings.TrimSpace(kv[1])
		n, err := strconv.ParseUint(val, 10, 64)
		if err != nil {
			continue
		}
		switch key {
		case "upload":
			up = n
		case "download":
			down = n
		case "total":
			total = n
		case "expire":
			if n > 0 {
				exp = time.Unix(int64(n), 0).UTC()
			}
		}
	}
	return up, down, total, exp
}

// decodeDataURL parses a `data:[<mime>][;base64],<payload>` URL and
// returns the decoded bytes plus the declared MIME type. The
// renderer's drag-and-drop import path always emits base64 — we
// reject the URL-encoded variant for simplicity since nothing in
// the app needs it.
func decodeDataURL(url string) ([]byte, string, error) {
	rest := strings.TrimPrefix(url, "data:")
	comma := strings.IndexByte(rest, ',')
	if comma < 0 {
		return nil, "", fmt.Errorf("data url: missing comma")
	}
	meta := rest[:comma]
	payload := rest[comma+1:]
	if !strings.Contains(meta, "base64") {
		return nil, "", fmt.Errorf("data url: only base64 payloads supported")
	}
	mime := strings.SplitN(meta, ";", 2)[0]
	if mime == "" {
		mime = "application/octet-stream"
	}
	decoded, err := base64.StdEncoding.DecodeString(payload)
	if err != nil {
		return nil, "", fmt.Errorf("data url: %w", err)
	}
	return decoded, mime, nil
}

func readAllLimited(r interface{ Read(p []byte) (int, error) }, max int64) ([]byte, error) {
	buf := make([]byte, 0, 4096)
	tmp := make([]byte, 4096)
	var total int64
	for {
		n, err := r.Read(tmp)
		if n > 0 {
			total += int64(n)
			if total > max {
				return nil, fmt.Errorf("response too large (>%d bytes)", max)
			}
			buf = append(buf, tmp[:n]...)
		}
		if err != nil {
			if err.Error() == "EOF" {
				return buf, nil
			}
			return buf, err
		}
	}
}
