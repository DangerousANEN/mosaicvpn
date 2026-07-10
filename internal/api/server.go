// Package api implements the HTTP API exposed by the Mosaic daemon on the
// loopback interface. The same API is consumed by the CLI, the Tauri UI,
// and the embedded MCP server.
//
// Authentication is a shared bearer token written into the lockfile on
// daemon start. Clients read the lockfile, attach `Authorization: Bearer
// <token>`, and the daemon rejects any request without a matching token.
package api

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/geoip"
	"github.com/pupspochta-cpu/mosaicvpn/internal/logx"
	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/state"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
	"github.com/pupspochta-cpu/mosaicvpn/internal/subs"
)

// Fetcher is the function used to retrieve subscription payloads. The
// daemon wires in an HTTP-backed implementation; tests can supply an
// in-memory one.
type Fetcher func(ctx context.Context, url string) ([]byte, string, error)

// Server bundles the daemon's HTTP API.
type Server struct {
	store   *store.Store
	mgr     *state.Manager
	token   string
	fetcher Fetcher

	mux *http.ServeMux
}

// NewServer constructs an API server.
func NewServer(s *store.Store, mgr *state.Manager, fetcher Fetcher) *Server {
	if fetcher == nil {
		fetcher = HTTPFetcher(http.DefaultClient)
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
	s.mux.HandleFunc("POST /v1/subscriptions/{id}/refresh", s.handleRefreshSub)
	s.mux.HandleFunc("PATCH /v1/subscriptions/{id}", s.handleRenameSub)
	s.mux.HandleFunc("DELETE /v1/subscriptions/{id}", s.handleDeleteSub)

	s.mux.HandleFunc("GET /v1/servers", s.handleListServers)
	s.mux.HandleFunc("POST /v1/servers/{id}/test", s.handleTestServer)
	s.mux.HandleFunc("POST /v1/servers/test-all", s.handleTestAll)

	s.mux.HandleFunc("GET /v1/rules", s.handleListRules)
	s.mux.HandleFunc("POST /v1/rules", s.handleAddRule)
	s.mux.HandleFunc("DELETE /v1/rules/{id}", s.handleDeleteRule)
	s.mux.HandleFunc("POST /v1/rules:reorder", s.handleReorderRules)

	s.mux.HandleFunc("GET /v1/prefs", s.handleGetPrefs)
	s.mux.HandleFunc("PUT /v1/prefs", s.handleSetPrefs)

	s.mux.HandleFunc("GET /v1/diag", s.handleDiag)
	s.mux.HandleFunc("GET /v1/events", s.handleEvents)
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
	// reload after refresh
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
	for _, su := range s.store.Snapshot().Subscriptions {
		if su.ID == id {
			writeJSON(w, http.StatusOK, su)
			return
		}
	}
	writeJSON(w, http.StatusOK, target)
}

func (s *Server) handleDeleteSub(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.store.DeleteSubscription(id); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleRenameSub(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	saved, err := s.store.RenameSubscription(id, req.Name)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, saved)
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
func probeServer(ctx context.Context, addr string, port int, timeout time.Duration) (int, string) {
	dialer := net.Dialer{Timeout: timeout}
	target := fmt.Sprintf("%s:%d", addr, port)
	t0 := time.Now()
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	conn, err := dialer.DialContext(cctx, "tcp", target)
	if err != nil {
		return -1, err.Error()
	}
	rtt := int(time.Since(t0).Milliseconds())
	if rtt < 1 {
		rtt = 1
	}
	_ = conn.Close()
	return rtt, ""
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
	ms, errMsg := probeServer(r.Context(), srv.Address, srv.Port, 5*time.Second)
	if err := s.store.RecordServerProbe(id, ms, errMsg); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if srv.Lat == 0 && srv.Lon == 0 {
		if geo, err := geoip.Lookup(r.Context(), srv.Address); err == nil {
			_ = s.store.RecordServerGeo(id, geo.City, geo.Country, geo.Lat, geo.Lon)
		}
	}
	updated, _ := s.store.FindServer(id)
	writeJSON(w, http.StatusOK, updated)
}

// handleTestAll probes every server (or all servers under a single
// subscription if subscription_id is provided) in parallel and returns
// the refreshed list.
func (s *Server) handleTestAll(w http.ResponseWriter, r *http.Request) {
	subID := r.URL.Query().Get("subscription_id")
	snap := s.store.Snapshot()
	targets := make([]proto.Server, 0, len(snap.Servers))
	for _, sv := range snap.Servers {
		if subID == "" || sv.SubscriptionID == subID {
			targets = append(targets, sv)
		}
	}
	const concurrency = 16
	sem := make(chan struct{}, concurrency)
	done := make(chan struct{}, len(targets))
	for _, sv := range targets {
		sv := sv
		sem <- struct{}{}
		go func() {
			defer func() { <-sem; done <- struct{}{} }()
			ms, errMsg := probeServer(r.Context(), sv.Address, sv.Port, 4*time.Second)
			_ = s.store.RecordServerProbe(sv.ID, ms, errMsg)
			if sv.Lat == 0 && sv.Lon == 0 {
				if geo, err := geoip.Lookup(r.Context(), sv.Address); err == nil {
					_ = s.store.RecordServerGeo(sv.ID, geo.City, geo.Country, geo.Lat, geo.Lon)
				}
			}
		}()
	}
	for range targets {
		<-done
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

	// If the tunnel is currently active, reconnect so the new prefs
	// (tunnel mode, kill switch, TUN stack) take effect immediately.
	st := s.mgr.Status()
	if st.State == proto.StateConnected || st.State == proto.StateConnecting {
		if st.Server != nil {
			serverID := st.Server.ID
			// Disconnect first, then reconnect in a goroutine so the
			// HTTP response is not blocked.  We use a fresh context
			// because r.Context() is cancelled once the handler returns.
			go func() {
				_ = s.mgr.Disconnect(context.Background())
				_ = s.mgr.Connect(context.Background(), serverID)
			}()
		}
	}

	writeJSON(w, http.StatusOK, p)
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

func (s *Server) refresh(ctx context.Context, sub proto.Subscription) error {
	body, _, err := s.fetcher(ctx, sub.URL)
	if err != nil {
		return fmt.Errorf("fetch: %w", err)
	}
	var res subs.Result
	if sub.Format != "" && sub.Format != proto.FormatUnknown {
		res, err = subs.ParseAs(sub.ID, body, sub.Format)
	} else {
		res, err = subs.Parse(sub.ID, body)
	}
	if err != nil {
		return fmt.Errorf("parse: %w", err)
	}
	sub.Format = res.Format
	sub.ServerCount = len(res.Servers)
	sub.LastFetched = time.Now().UTC()
	sub.LastError = ""
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

// HTTPFetcher returns a Fetcher that uses the supplied HTTP client.
func HTTPFetcher(client *http.Client) Fetcher {
	if client == nil {
		client = http.DefaultClient
	}
	return func(ctx context.Context, url string) ([]byte, string, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, "", err
		}
		req.Header.Set("User-Agent", "Mosaic/0.1")
		resp, err := client.Do(req)
		if err != nil {
			return nil, "", err
		}
		defer resp.Body.Close()
		if resp.StatusCode/100 != 2 {
			return nil, "", fmt.Errorf("http %s", resp.Status)
		}
		body, err := readAllLimited(resp.Body, 16<<20) // 16 MiB cap
		if err != nil {
			return nil, "", err
		}
		return body, resp.Header.Get("Content-Type"), nil
	}
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
