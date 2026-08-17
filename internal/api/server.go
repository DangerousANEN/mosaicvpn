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
	"sync"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/billing"
	"github.com/pupspochta-cpu/mosaicvpn/internal/geoip"
	"github.com/pupspochta-cpu/mosaicvpn/internal/logx"
	"github.com/pupspochta-cpu/mosaicvpn/internal/mcp"
	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/state"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
	"github.com/pupspochta-cpu/mosaicvpn/internal/subs"
	"github.com/pupspochta-cpu/mosaicvpn/internal/telemetry"
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
	billing *billing.Client
	lava    billing.PaymentProvider
	// linkVerifier redeems pairing codes against the bot. Nil means
	// self-hosted mode: codes are issued and burned locally.
	linkVerifier       LinkVerifier
	emailAuthenticator EmailAuthenticator
	activeManifest     *proto.SubscriptionManifest
	manifestMu         sync.RWMutex
	pool               *subs.PoolEngine

	shutdownRequested chan struct{}
	shutdownOnce      sync.Once
	mux               *http.ServeMux
}

// NewServer constructs an API server.
func NewServer(s *store.Store, mgr *state.Manager, fetcher Fetcher) *Server {
	if fetcher == nil {
		fetcher = HTTPFetcher(http.DefaultClient)
	}
	srv := &Server{
		store:             s,
		mgr:               mgr,
		token:             newToken(),
		fetcher:           fetcher,
		billing:           billing.NewClient(billing.Config{}),
		lava:              billing.NewLavaProvider(),
		pool:              subs.NewPoolEngine(),
		shutdownRequested: make(chan struct{}),
		mux:               http.NewServeMux(),
	}
	srv.routes()
	return srv
}

// SetBillingConfig updates the upstream Remnawave/CryptoBot credentials.
// Called when the daemon loads or the user changes billing settings.
func (s *Server) SetBillingConfig(cfg billing.Config) {
	if s.billing != nil {
		s.billing.UpdateConfig(cfg)
	}
}

// SetLavaProvider replaces the Lava payment provider instance.
// SetLinkVerifier installs the remote pairing-code authority.
func (s *Server) SetLinkVerifier(v LinkVerifier) { s.linkVerifier = v }

// SetEmailAuthenticator installs the remote password authority for non-Telegram accounts.
func (s *Server) SetEmailAuthenticator(v EmailAuthenticator) { s.emailAuthenticator = v }

func (s *Server) SetLavaProvider(p billing.PaymentProvider) {
	s.lava = p
}

// Token returns the secret bearer token. It is written into the lockfile
// so trusted local clients can authenticate.
func (s *Server) Token() string { return s.token }

// ShutdownRequested is closed after an authenticated local client asks the
// daemon to stop. The process owner performs the actual orderly shutdown so
// the connection manager can stop its child runtime before lockfile cleanup.
func (s *Server) ShutdownRequested() <-chan struct{} { return s.shutdownRequested }

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
	mcpServer := mcp.NewServer(s.store, s.mgr)
	s.mux.Handle("/mcp", mcpServer)
	s.mux.Handle("POST /mcp", mcpServer)
	s.mux.Handle("GET /mcp", mcpServer)

	s.mux.HandleFunc("GET /v1/status", s.handleStatus)
	s.mux.HandleFunc("POST /v1/connect", s.handleConnect)
	s.mux.HandleFunc("POST /v1/disconnect", s.handleDisconnect)
	s.mux.HandleFunc("POST /v1/runtime/shutdown", s.handleRuntimeShutdown)

	s.mux.HandleFunc("GET /v1/subscriptions", s.handleListSubs)
	s.mux.HandleFunc("POST /v1/subscriptions", s.handleAddSub)
	s.mux.HandleFunc("POST /v1/subscriptions/refresh-all", s.handleRefreshAllSubs)
	s.mux.HandleFunc("POST /v1/subscriptions:reorder", s.handleReorderSubs)
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
	s.mux.HandleFunc("POST /v1/telemetry", s.handleTelemetry)
	s.mux.HandleFunc("GET /v1/manifest", s.handleGetManifest)

	// Profiles
	s.mux.HandleFunc("GET /v1/profiles", s.handleListProfiles)
	s.mux.HandleFunc("POST /v1/profiles", s.handleCreateProfile)
	s.mux.HandleFunc("PUT /v1/profiles/{id}", s.handleUpdateProfile)
	s.mux.HandleFunc("DELETE /v1/profiles/{id}", s.handleDeleteProfile)
	s.mux.HandleFunc("POST /v1/profiles/{id}/activate", s.handleActivateProfile)

	// Route Profiles
	s.mux.HandleFunc("GET /v1/route-profiles", s.handleListRouteProfiles)
	s.mux.HandleFunc("POST /v1/route-profiles", s.handleCreateRouteProfile)
	s.mux.HandleFunc("PUT /v1/route-profiles/{id}", s.handleUpdateRouteProfile)
	s.mux.HandleFunc("DELETE /v1/route-profiles/{id}", s.handleDeleteRouteProfile)

	// Billing endpoints — bridge to Remnawave + CryptoBot.
	s.mux.HandleFunc("GET /v1/billing/profile", s.handleBillingProfile)
	s.mux.HandleFunc("POST /v1/billing/link", s.handleBillingLink)

	// Account cabinet: code/email sign-in plus the hosted unified account.
	s.mux.HandleFunc("POST /v1/account/link-code", s.handleLinkCodeIssue)
	s.mux.HandleFunc("POST /v1/account/link", s.handleLinkCodeRedeem)
	s.mux.HandleFunc("POST /v1/account/email-login", s.handleEmailLogin)
	s.mux.HandleFunc("GET /v1/account/payments", s.handlePaymentHistory)
	s.mux.HandleFunc("GET /v1/account/overview", s.handleUnifiedAccountProfile)
	s.mux.HandleFunc("POST /v1/account/freeze", s.handleAccountAccessAction("freeze"))
	s.mux.HandleFunc("POST /v1/account/unfreeze", s.handleAccountAccessAction("unfreeze"))
	s.mux.HandleFunc("POST /v1/account/subscription-link/rotate", s.handleSubscriptionLinkRotate)
	s.mux.HandleFunc("POST /v1/billing/unlink", s.handleBillingUnlink)
	s.mux.HandleFunc("POST /v1/billing/topup", s.handleBillingTopup)
	s.mux.HandleFunc("GET /v1/billing/topup/{id}", s.handleBillingTopupStatus)
	// Unified checkout is provider-neutral; the hosted authority selects the
	// enabled provider, currently Crypto Pay and later Lava/SBP.
	s.mux.HandleFunc("GET /v1/billing/checkout-options", s.handleCheckoutOptions)
	s.mux.HandleFunc("POST /v1/billing/checkout", s.handleCheckoutCreate)
	s.mux.HandleFunc("GET /v1/billing/checkout/{invoiceID}", s.handleCheckoutStatus)
	s.mux.HandleFunc("GET /v1/billing/config", s.handleBillingConfigGet)
	s.mux.HandleFunc("PUT /v1/billing/config", s.handleBillingConfigSet)

	// YooKassa (ЮKassa) payment endpoints
	s.mux.HandleFunc("POST /v1/billing/yookassa/create", s.handleYookassaCreate)
	s.mux.HandleFunc("GET /v1/billing/yookassa/status", s.handleYookassaStatus)
	s.mux.HandleFunc("POST /v1/billing/yookassa/webhook", s.handleYookassaWebhook)

	// Lava payment endpoints
	s.mux.HandleFunc("POST /v1/billing/lava/create", s.handleLavaCreate)
	s.mux.HandleFunc("GET /v1/billing/lava/status/{id}", s.handleLavaStatus)
	s.mux.HandleFunc("POST /v1/billing/lava/webhook", s.handleLavaWebhook)

	// Promo codes
	s.mux.HandleFunc("POST /v1/promo/create", s.handlePromoCreate)
	s.mux.HandleFunc("GET /v1/promo/list", s.handlePromoList)
	s.mux.HandleFunc("POST /v1/promo/redeem", s.handlePromoRedeem)

	// Connections
	s.mux.HandleFunc("GET /v1/connections", s.handleListConnections)
	s.mux.HandleFunc("POST /v1/connections/{id}/close", s.handleCloseConnection)
	s.mux.HandleFunc("POST /v1/connections/close-all", s.handleCloseAllConnections)

	// Stats
	s.mux.HandleFunc("GET /v1/stats", s.handleGetStats)
	s.mux.HandleFunc("POST /v1/stats/reset", s.handleResetStats)

	// DNS
	s.mux.HandleFunc("GET /v1/dns", s.handleGetDNS)
	s.mux.HandleFunc("PUT /v1/dns", s.handleSetDNS)

	// Tests
	s.mux.HandleFunc("POST /v1/test/url", s.handleTestURL)
	s.mux.HandleFunc("POST /v1/test/ip", s.handleTestIP)
	s.mux.HandleFunc("POST /v1/test/speed", s.handleSpeedTest)

	// WARP
	s.mux.HandleFunc("GET /v1/warp", s.handleGetWARP)
	s.mux.HandleFunc("PUT /v1/warp", s.handleSetWARP)

	// Import
	s.mux.HandleFunc("POST /v1/import/clipboard", s.handleImportClipboard)
	s.mux.HandleFunc("POST /v1/import/link", s.handleImportLink)

	s.mux.HandleFunc("GET /v1/diag", s.handleDiag)
	s.mux.HandleFunc("GET /v1/events", s.handleEvents)

	// Egresses (multi-proxy listeners)
	s.mux.HandleFunc("GET /v1/egresses", s.handleListEgresses)
	s.mux.HandleFunc("POST /v1/egresses", s.handleAddEgress)
	s.mux.HandleFunc("PUT /v1/egresses/{id}", s.handleUpdateEgress)
	s.mux.HandleFunc("DELETE /v1/egresses/{id}", s.handleDeleteEgress)
	s.mux.HandleFunc("POST /v1/egresses/{id}/toggle", s.handleToggleEgress)

	// Export / Import
	s.mux.HandleFunc("GET /v1/export", s.handleExport)
	s.mux.HandleFunc("POST /v1/import", s.handleImport)

	// Anti-DPI
	s.mux.HandleFunc("GET /v1/anti-dpi", s.handleGetAntiDPI)
	s.mux.HandleFunc("PUT /v1/anti-dpi", s.handleSetAntiDPI)

	// Local server and collection operations.
	s.mux.HandleFunc("POST /v1/servers", s.handleAddLocalServer)
	s.mux.HandleFunc("DELETE /v1/servers/{id}", s.handleDeleteLocalServer)
	s.mux.HandleFunc("GET /v1/groups", s.handleListLocalGroups)
	s.mux.HandleFunc("POST /v1/groups", s.handleCreateLocalGroup)
	s.mux.HandleFunc("DELETE /v1/groups/{id}", s.handleDeleteLocalGroup)
	s.mux.HandleFunc("POST /v1/servers/{id}/move", s.handleMoveServer)
	s.mux.HandleFunc("POST /v1/servers/test-group", s.handleTestSpeedGroup)

	// Pool / Group selection
	s.mux.HandleFunc("GET /v1/groups/{groupID}/select", s.handleGroupSelect)
	s.mux.HandleFunc("GET /v1/groups/{groupID}/health", s.handleGroupHealth)
	s.mux.HandleFunc("GET /v1/health", s.handleAllHealth)
	s.mux.HandleFunc("GET /v1/services/{id}/resolve", s.handleResolveService)
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
	// Walk the priority chain unless the caller pinned a node. An older client
	// that sends only server_id keeps working: a pinned ID short-circuits the
	// chain and behaves exactly as before.
	res, err := state.Resolve(s.store, req.GroupID, req.ServerID)
	if err != nil {
		var rerr *state.ResolveError
		if errors.As(err, &rerr) {
			// Report the reason and the steps tried instead of a bare failure,
			// so the UI can explain the problem and offer a retry.
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{
				"error":     rerr.Reason,
				"details":   rerr.Details,
				"tried":     rerr.Tried,
				"retryable": rerr.Retryable,
			})
			return
		}
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	if err := s.mgr.Connect(r.Context(), res.ServerID); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	// Remember the group only after the connection actually came up, so a
	// failing group does not become the preferred choice next time.
	if res.GroupID != "" {
		if err := s.store.SetLastGroup(res.GroupID); err != nil {
			logx.Warn("connect: remember last group", "group", res.GroupID, "err", err)
		}
	}

	writeJSON(w, http.StatusOK, proto.ConnectResponse{
		Status:      s.mgr.Status(),
		ResolvedVia: string(res.Step),
		GroupID:     res.GroupID,
		Degraded:    res.Degraded,
		Notes:       res.Notes,
	})
}

func (s *Server) handleDisconnect(w http.ResponseWriter, r *http.Request) {
	if err := s.mgr.Disconnect(r.Context()); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.mgr.Status())
}

// handleRuntimeShutdown accepts an authenticated request from the local client
// before it closes. Disconnecting here makes the intended ordering explicit;
// cmd/mosaicd then receives the shutdown signal and closes its listener and
// lockfile. The channel is closed once, making repeated tray clicks harmless.
func (s *Server) handleRuntimeShutdown(w http.ResponseWriter, r *http.Request) {
	if err := s.mgr.Disconnect(r.Context()); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "state": "stopping"})
	s.shutdownOnce.Do(func() { close(s.shutdownRequested) })
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
	// Fetch & parse synchronously so the response immediately contains servers
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	if err := s.refresh(ctx, sub); err != nil {
		_ = s.store.MarkSubscriptionError(sub.ID, err.Error())
	}
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

func (s *Server) handleRefreshAllSubs(w http.ResponseWriter, r *http.Request) {
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		s.refreshAllSubscriptions(ctx)
	}()
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "message": "Background sync started"})
}

func (s *Server) handleReorderSubs(w http.ResponseWriter, r *http.Request) {
	var req struct {
		SubscriptionIDs []string `json:"subscription_ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if err := s.store.ReorderSubscriptions(req.SubscriptionIDs); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.store.Snapshot().Subscriptions)
}

func (s *Server) StartAutoUpdate(ctx context.Context) {
	// 1. Initial background refresh on daemon startup
	go func() {
		ctxSync, cancel := context.WithTimeout(ctx, 45*time.Second)
		defer cancel()
		s.refreshAllSubscriptions(ctxSync)
	}()

	// 2. Periodic sync every 4 hours
	ticker := time.NewTicker(4 * time.Hour)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			ctxSync, cancel := context.WithTimeout(ctx, 45*time.Second)
			s.refreshAllSubscriptions(ctxSync)
			cancel()
		}
	}
}

func (s *Server) refreshAllSubscriptions(ctx context.Context) {
	subs := s.store.Snapshot().Subscriptions
	if len(subs) == 0 {
		return
	}
	anyUpdated := false
	for _, sub := range subs {
		if !sub.AutoRefresh {
			continue
		}
		if err := s.refresh(ctx, sub); err == nil {
			anyUpdated = true
		} else {
			logx.Warn("auto-update subscription refresh error", "sub", sub.Name, "err", err)
		}
	}
	if anyUpdated {
		_ = s.mgr.HotReload(ctx)
	}
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
	out := make([]proto.Server, 0, len(snap.Servers))
	for _, sv := range snap.Servers {
		if subID != "" && sv.SubscriptionID != subID {
			continue
		}
		// Mosaic direct nodes are service infrastructure, not a user-selectable
		// resource. Users select a named smart group; only the daemon resolves
		// physical candidates, addresses and IDs inside the protected pool.
		if sv.SubscriptionID == "mosaic-direct" && !sv.IsVirtualGroup {
			continue
		}
		out = append(out, sv)
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
	oldPrefs := s.store.Snapshot().Prefs
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

	// Determine if tunnel-affecting settings changed
	tunnelChanged := oldPrefs.TunnelMode != p.TunnelMode ||
		oldPrefs.TunStack != p.TunStack ||
		oldPrefs.MTU != p.MTU ||
		oldPrefs.KillSwitch != p.KillSwitch ||
		oldPrefs.AllowLAN != p.AllowLAN ||
		oldPrefs.ShareLAN != p.ShareLAN ||
		oldPrefs.BlockIPv6 != p.BlockIPv6 ||
		oldPrefs.DNSMode != p.DNSMode ||
		oldPrefs.DNSProxied != p.DNSProxied ||
		oldPrefs.DNSDirect != p.DNSDirect ||
		oldPrefs.SocksAddr != p.SocksAddr ||
		oldPrefs.HTTPAddr != p.HTTPAddr

	st := s.mgr.Status()
	if tunnelChanged && (st.State == proto.StateConnected || st.State == proto.StateConnecting) && st.Server != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		err := s.mgr.HotReload(ctx)
		cancel()
		if err != nil {
			// Do not leave the UI and runtime disagreeing about the active prefs.
			_ = s.store.SetPrefs(oldPrefs)
			s.mgr.SetTunnelPrefs(oldPrefs.TunnelMode, oldPrefs.KillSwitch)
			writeError(w, http.StatusServiceUnavailable, fmt.Sprintf("settings were not applied: %v", err))
			return
		}
	}

	writeJSON(w, http.StatusOK, p)
}

func (s *Server) handleTelemetry(w http.ResponseWriter, r *http.Request) {
	var rep telemetry.Report
	if err := json.NewDecoder(r.Body).Decode(&rep); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	// Broadcast telemetry to provider if configured
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
}

// ---------- Profile handlers ---------------------------------------------

func (s *Server) handleListProfiles(w http.ResponseWriter, _ *http.Request) {
	snap := s.store.Snapshot()
	profiles := snap.Profiles
	if profiles == nil {
		profiles = []proto.Profile{}
	}
	writeJSON(w, http.StatusOK, profiles)
}

func (s *Server) handleCreateProfile(w http.ResponseWriter, r *http.Request) {
	var p proto.Profile
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if p.Name == "" {
		writeError(w, http.StatusBadRequest, "name required")
		return
	}
	saved, err := s.store.AddOrUpdateProfile(p)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, saved)
}

func (s *Server) handleUpdateProfile(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var p proto.Profile
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	p.ID = id
	saved, err := s.store.AddOrUpdateProfile(p)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, saved)
}

func (s *Server) handleDeleteProfile(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.store.DeleteProfile(id); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleActivateProfile(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.store.SetActiveProfile(id); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.mgr.Status())
}

// ---------- Route Profile handlers ---------------------------------------

func (s *Server) handleListRouteProfiles(w http.ResponseWriter, _ *http.Request) {
	snap := s.store.Snapshot()
	rps := snap.RouteProfiles
	if rps == nil {
		rps = []proto.RouteProfile{}
	}
	writeJSON(w, http.StatusOK, rps)
}

func (s *Server) handleCreateRouteProfile(w http.ResponseWriter, r *http.Request) {
	var rp proto.RouteProfile
	if err := json.NewDecoder(r.Body).Decode(&rp); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if rp.Name == "" {
		writeError(w, http.StatusBadRequest, "name required")
		return
	}
	saved, err := s.store.AddOrUpdateRouteProfile(rp)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, saved)
}

func (s *Server) handleUpdateRouteProfile(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var rp proto.RouteProfile
	if err := json.NewDecoder(r.Body).Decode(&rp); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	rp.ID = id
	saved, err := s.store.AddOrUpdateRouteProfile(rp)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, saved)
}

func (s *Server) handleDeleteRouteProfile(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.store.DeleteRouteProfile(id); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- Connection handlers ------------------------------------------

func (s *Server) handleListConnections(w http.ResponseWriter, _ *http.Request) {
	conns := s.mgr.Connections()
	if conns == nil {
		conns = []proto.Connection{}
	}
	writeJSON(w, http.StatusOK, conns)
}

func (s *Server) handleCloseConnection(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.mgr.CloseConnection(id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleCloseAllConnections(w http.ResponseWriter, _ *http.Request) {
	if err := s.mgr.CloseAllConnections(); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- Stats handlers -----------------------------------------------

func (s *Server) handleGetStats(w http.ResponseWriter, _ *http.Request) {
	stats := s.mgr.Stats()
	writeJSON(w, http.StatusOK, stats)
}

func (s *Server) handleResetStats(w http.ResponseWriter, _ *http.Request) {
	if err := s.mgr.ResetStats(); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- DNS handlers --------------------------------------------------

func (s *Server) handleGetDNS(w http.ResponseWriter, _ *http.Request) {
	snap := s.store.Snapshot()
	dns := proto.DNSConfig{
		Mode:    snap.Prefs.DNSMode,
		Proxied: snap.Prefs.DNSProxied,
		Direct:  snap.Prefs.DNSDirect,
	}
	if dns.Mode == "" {
		dns = proto.DefaultDNSConfig()
	}
	writeJSON(w, http.StatusOK, dns)
}

func (s *Server) handleSetDNS(w http.ResponseWriter, r *http.Request) {
	var dns proto.DNSConfig
	if err := json.NewDecoder(r.Body).Decode(&dns); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if err := s.store.Update(func(st *store.State) error {
		st.Prefs.DNSMode = dns.Mode
		st.Prefs.DNSProxied = dns.Proxied
		st.Prefs.DNSDirect = dns.Direct
		return nil
	}); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, dns)
}

// ---------- Test handlers -------------------------------------------------

func (s *Server) handleTestURL(w http.ResponseWriter, r *http.Request) {
	var req struct {
		URL string `json:"url"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if req.URL == "" {
		writeError(w, http.StatusBadRequest, "url required")
		return
	}
	result, err := s.mgr.TestURL(r.Context(), req.URL)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleTestIP(w http.ResponseWriter, r *http.Request) {
	info, err := s.mgr.TestIP(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, info)
}

func (s *Server) handleSpeedTest(w http.ResponseWriter, r *http.Request) {
	result, err := s.mgr.SpeedTest(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, result)
}

// ---------- WARP handlers -------------------------------------------------

func (s *Server) handleGetWARP(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.store.GetWARP())
}

func (s *Server) handleSetWARP(w http.ResponseWriter, r *http.Request) {
	var cfg proto.WARPConfig
	if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if err := s.store.SetWARP(cfg); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, cfg)
}

// ---------- Import handlers -----------------------------------------------

func (s *Server) handleImportClipboard(w http.ResponseWriter, r *http.Request) {
	// The actual clipboard read is done on the Tauri (Rust) side; the
	// daemon just parses the raw string.  The UI calls the Tauri command
	// to read the clipboard, then sends the raw content here.
	var req struct {
		Raw string `json:"raw"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if req.Raw == "" {
		writeError(w, http.StatusBadRequest, "raw required")
		return
	}
	imp := s.parseImport(req.Raw)
	writeJSON(w, http.StatusOK, imp)
}

func (s *Server) handleImportLink(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Raw string `json:"raw"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if req.Raw == "" {
		writeError(w, http.StatusBadRequest, "raw required")
		return
	}
	imp := s.parseImport(req.Raw)
	writeJSON(w, http.StatusOK, imp)
}

// parseImport attempts to identify the protocol of a raw share link.
func (s *Server) parseImport(raw string) proto.ClipboardImport {
	imp := proto.ClipboardImport{Raw: raw}
	switch {
	case strings.HasPrefix(raw, "vless://"):
		imp.Protocol = proto.ProtoVLESS
		imp.Parsed = true
	case strings.HasPrefix(raw, "vmess://"):
		imp.Protocol = proto.ProtoVMess
		imp.Parsed = true
	case strings.HasPrefix(raw, "trojan://"):
		imp.Protocol = proto.ProtoTrojan
		imp.Parsed = true
	case strings.HasPrefix(raw, "ss://"):
		imp.Protocol = proto.ProtoShadowsocks
		imp.Parsed = true
	case strings.HasPrefix(raw, "hysteria2://"), strings.HasPrefix(raw, "hy2://"):
		imp.Protocol = proto.ProtoHysteria2
		imp.Parsed = true
	default:
		imp.Error = "unrecognised link format"
	}
	return imp
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

func (s *Server) handleGetManifest(w http.ResponseWriter, _ *http.Request) {
	s.manifestMu.RLock()
	m := s.activeManifest
	s.manifestMu.RUnlock()

	if m == nil {
		snap := s.store.Snapshot()
		if snap.ActiveManifest != nil && len(snap.ActiveManifest.Groups) > 0 {
			m = snap.ActiveManifest
		} else {
			// Do not synthesize Mosaic routes from manually imported nodes. Until
			// an authenticated Mosaic account loads its direct feed, the dashboard
			// intentionally has no Mosaic smart groups to offer.
			empty := proto.SubscriptionManifest{
				ProviderName: "MosaicVPN",
				UserTier:     proto.TierFree,
				Groups:       []proto.ManifestGroup{},
			}
			m = &empty
		}
	}
	writeJSON(w, http.StatusOK, m)
}

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

	manifestBytes := body
	if provManifest, err := subs.FetchProviderManifest(ctx, sub.URL); err == nil && provManifest != nil {
		if b, err := json.Marshal(provManifest); err == nil {
			manifestBytes = b
		}
	}

	manifest, finalServers := subs.ParseManifestOrSynthesize(manifestBytes, sub.ID, res.Servers)
	// The account-owned Mosaic feed is the sole source of global smart routes.
	// When its feed does not provide a separate manifest, build service groups
	// from its private nodes. The client receives only group names/strategies;
	// physical nodes remain filtered out by handleListServers.
	if sub.ID == "mosaic-direct" && len(manifest.Groups) == 0 {
		manifest = subs.SynthesizeManifest(sub.ID, res.Servers)
		finalServers = append(
			subs.BuildVirtualServersFromManifest(manifest, sub.ID),
			res.Servers...,
		)
	}
	if sub.ID == "mosaic-direct" {
		if err := s.syncMosaicGroups(manifest); err != nil {
			return fmt.Errorf("sync Mosaic groups: %w", err)
		}
		s.manifestMu.Lock()
		s.activeManifest = &manifest
		s.manifestMu.Unlock()
		if err := s.store.SaveManifest(&manifest); err != nil {
			return fmt.Errorf("save Mosaic manifest: %w", err)
		}
	}

	sub.Format = res.Format
	sub.ServerCount = len(finalServers)
	sub.LastFetched = time.Now().UTC()
	sub.LastError = ""
	if _, err := s.store.AddOrUpdateSubscription(sub); err != nil {
		return err
	}
	return s.store.ReplaceServersFor(sub.ID, finalServers)
}

// syncMosaicGroups mirrors the public manifest into the resolver's local
// group store. The node references stay daemon-side, while the UI sees the
// manifest alone and connects using group_id rather than an endpoint.
func (s *Server) syncMosaicGroups(manifest proto.SubscriptionManifest) error {
	for _, manifestGroup := range manifest.Groups {
		group := manifestGroup.ToServerGroup()
		group.Source = proto.GroupSourcePool
		group.Description = manifestGroup.Description
		group.Icon = manifestGroup.Icon
		if err := s.store.SaveGroup(group); err != nil {
			return err
		}
	}
	return nil
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
		req.Header.Set("User-Agent", "v2rayN/6.39 sing-box/1.9.0 ClashforWindows/0.20.39 Mosaic/1.0.0")
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

// ---------- Egress handlers -----------------------------------------------

func (s *Server) handleListEgresses(w http.ResponseWriter, _ *http.Request) {
	eg := s.store.ListEgresses()
	if eg == nil {
		eg = []proto.Egress{}
	}
	writeJSON(w, http.StatusOK, eg)
}

func (s *Server) handleAddEgress(w http.ResponseWriter, r *http.Request) {
	var e proto.Egress
	if err := json.NewDecoder(r.Body).Decode(&e); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if e.Name == "" {
		writeError(w, http.StatusBadRequest, "name required")
		return
	}
	if e.Protocol == "" {
		e.Protocol = "mixed"
	}
	if e.Listen == "" {
		e.Listen = "127.0.0.1:0"
	}
	saved, err := s.store.AddEgress(e)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	_ = s.mgr.HotReload(context.Background())
	writeJSON(w, http.StatusOK, saved)
}

func (s *Server) handleUpdateEgress(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var e proto.Egress
	if err := json.NewDecoder(r.Body).Decode(&e); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	e.ID = id
	if err := s.store.UpdateEgress(e); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	_ = s.mgr.HotReload(context.Background())
	writeJSON(w, http.StatusOK, e)
}

func (s *Server) handleDeleteEgress(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.store.DeleteEgress(id); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	_ = s.mgr.HotReload(context.Background())
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleToggleEgress(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req struct {
		Active bool `json:"active"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if err := s.store.ToggleEgress(id, req.Active); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	st := s.mgr.Status()
	if st.State == proto.StateConnected || st.State == proto.StateConnecting {
		if err := s.mgr.HotReload(r.Context()); err != nil {
			_ = s.store.ToggleEgress(id, !req.Active)
			writeError(w, http.StatusServiceUnavailable, fmt.Sprintf("egress was not applied: %v", err))
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- Export / Import handlers --------------------------------------

func (s *Server) handleExport(w http.ResponseWriter, r *http.Request) {
	include := r.URL.Query().Get("include_subscriptions") != "false"
	state := s.store.ExportState(include)
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handleImport(w http.ResponseWriter, r *http.Request) {
	var req proto.ImportRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	mode := req.Mode
	if mode == "" {
		mode = "merge"
	}
	// Convert the generic map into a State via JSON round-trip.
	raw, err := json.Marshal(req.Config)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid config payload")
		return
	}
	var data store.State
	if err := json.Unmarshal(raw, &data); err != nil {
		writeError(w, http.StatusBadRequest, "cannot parse config: "+err.Error())
		return
	}
	if err := s.store.ImportState(data, mode); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "mode": mode})
}

// ---------- Anti-DPI handlers ---------------------------------------------

func (s *Server) handleGetAntiDPI(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.store.GetAntiDPI())
}

func (s *Server) handleSetAntiDPI(w http.ResponseWriter, r *http.Request) {
	var a proto.AntiDPIConfig
	if err := json.NewDecoder(r.Body).Decode(&a); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if err := s.store.SetAntiDPI(a); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a)
}

// ---------- Server group handlers -----------------------------------------

const localCollectionID = "local-default"

func (s *Server) ensureLocalCollection() error {
	for _, sub := range s.store.Snapshot().Subscriptions {
		if sub.ID == localCollectionID {
			return nil
		}
	}
	_, err := s.store.AddOrUpdateSubscription(proto.Subscription{
		ID:                     localCollectionID,
		Name:                   "Локальные серверы",
		URL:                    "local://manual",
		Format:                 proto.FormatUnknown,
		AutoRefresh:            false,
		RefreshIntervalSeconds: 0,
	})
	return err
}

func (s *Server) handleListLocalGroups(w http.ResponseWriter, _ *http.Request) {
	groups := make([]proto.ServerGroup, 0)
	for _, group := range s.store.Groups() {
		if group.Source == proto.GroupSourceUser {
			groups = append(groups, group)
		}
	}
	writeJSON(w, http.StatusOK, groups)
}

func (s *Server) handleCreateLocalGroup(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	name := strings.TrimSpace(req.Name)
	if name == "" {
		writeError(w, http.StatusBadRequest, "group name required")
		return
	}
	if len([]rune(name)) > 80 {
		writeError(w, http.StatusBadRequest, "group name is too long")
		return
	}
	if err := s.ensureLocalCollection(); err != nil {
		writeError(w, http.StatusInternalServerError, "create local collection: "+err.Error())
		return
	}
	group := proto.ServerGroup{
		ID:          fmt.Sprintf("local-group-%d", time.Now().UnixNano()),
		Title:       name,
		Source:      proto.GroupSourceUser,
		Strategy:    proto.GroupStrategyFallback,
		Description: "Личный сборник серверов",
		Icon:        "folder",
		Nodes:       []proto.NodeRef{},
	}
	if err := s.store.SaveGroup(group); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, group)
}

func (s *Server) handleDeleteLocalGroup(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	group, ok := s.store.Group(id)
	if !ok || group.Source != proto.GroupSourceUser {
		writeError(w, http.StatusNotFound, "local group not found")
		return
	}
	if err := s.store.DeleteGroup(id); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleAddLocalServer(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Server proto.Server `json:"server"`
		RawURI string       `json:"raw_uri"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	server := req.Server
	if req.RawURI != "" {
		parsed, err := subs.Parse(server.SubscriptionID, []byte(req.RawURI))
		if err != nil || len(parsed.Servers) == 0 {
			writeError(w, http.StatusBadRequest, "could not parse server link")
			return
		}
		server = parsed.Servers[0]
		if req.Server.Name != "" {
			server.Name = req.Server.Name
		}
		server.Tag = req.Server.Tag
	}
	if server.Address == "" || server.Port <= 0 || server.Protocol == "" {
		writeError(w, http.StatusBadRequest, "server address, port and protocol are required")
		return
	}
	if err := s.ensureLocalCollection(); err != nil {
		writeError(w, http.StatusInternalServerError, "create local collection: "+err.Error())
		return
	}
	server.ID = ""
	server.SubscriptionID = localCollectionID
	saved, err := s.store.AddLocalServer(server)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, saved)
}

func (s *Server) handleDeleteLocalServer(w http.ResponseWriter, r *http.Request) {
	if err := s.store.DeleteServer(r.PathValue("id")); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMoveServer(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req struct {
		GroupID string `json:"group_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if err := s.store.SetServerGroup(id, req.GroupID); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleTestSpeedGroup(w http.ResponseWriter, r *http.Request) {
	var req struct {
		GroupID string `json:"group_id"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)

	snap := s.store.Snapshot()
	targets := make([]proto.Server, 0)
	for _, sv := range snap.Servers {
		if req.GroupID == "" || sv.Tag == req.GroupID {
			targets = append(targets, sv)
		}
	}

	const concurrency = 16
	sem := make(chan struct{}, concurrency)
	results := make([]proto.TestResult, len(targets))
	var wg sync.WaitGroup
	for i, sv := range targets {
		sv := sv
		i := i
		sem <- struct{}{}
		wg.Add(1)
		go func() {
			defer func() { <-sem; wg.Done() }()
			ms, errMsg := probeServer(r.Context(), sv.Address, sv.Port, 4*time.Second)
			_ = s.store.RecordServerProbe(sv.ID, ms, errMsg)
			results[i] = proto.TestResult{
				ServerID:   sv.ID,
				ServerName: sv.Name,
				LatencyMS:  ms,
				Error:      errMsg,
				TestedAt:   time.Now(),
			}
		}()
	}
	wg.Wait()
	if results == nil {
		results = []proto.TestResult{}
	}
	writeJSON(w, http.StatusOK, results)
}

// ---------- Pool / Group selection handlers --------------------------------

// StartPool launches the background health-check loop using the current
// manifest and server list from the store.
func (s *Server) StartPool(ctx context.Context) {
	s.manifestMu.RLock()
	manifest := s.activeManifest
	s.manifestMu.RUnlock()
	snap := s.store.Snapshot()
	if manifest == nil || len(manifest.Groups) == 0 {
		return
	}
	s.pool.Start(ctx, manifest.Groups, snap.Servers)
}

func (s *Server) handleGroupSelect(w http.ResponseWriter, r *http.Request) {
	groupID := r.PathValue("groupID")
	if groupID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing groupID"})
		return
	}
	s.manifestMu.RLock()
	manifest := s.activeManifest
	s.manifestMu.RUnlock()
	if manifest == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no manifest loaded"})
		return
	}
	var group *proto.ManifestGroup
	for i := range manifest.Groups {
		if manifest.Groups[i].ID == groupID {
			group = &manifest.Groups[i]
			break
		}
	}
	if group == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "group not found"})
		return
	}
	// Returning a selected physical node would reveal internal pool metadata to
	// the UI. Callers must use POST /v1/connect with {"group_id": ...}; the
	// daemon resolves and dials the candidate atomically.
	writeJSON(w, http.StatusGone, map[string]string{
		"error": "physical node selection is private; connect using group_id",
	})
}

func (s *Server) handleGroupHealth(w http.ResponseWriter, r *http.Request) {
	groupID := r.PathValue("groupID")
	if groupID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing groupID"})
		return
	}
	s.manifestMu.RLock()
	manifest := s.activeManifest
	s.manifestMu.RUnlock()
	if manifest == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no manifest loaded"})
		return
	}
	var group *proto.ManifestGroup
	for i := range manifest.Groups {
		if manifest.Groups[i].ID == groupID {
			group = &manifest.Groups[i]
			break
		}
	}
	if group == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "group not found"})
		return
	}
	// Pool health includes physical node IDs and must remain server-side. The
	// public manifest is the complete user-facing route capability contract.
	writeJSON(w, http.StatusGone, map[string]string{
		"error": "per-node health is private for provider smart groups",
	})
}

func (s *Server) handleAllHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.pool.GetAllHealth())
}

func (s *Server) handleResolveService(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing service id")
		return
	}
	s.manifestMu.RLock()
	manifest := s.activeManifest
	s.manifestMu.RUnlock()

	if manifest == nil || manifest.Profile == nil {
		writeError(w, http.StatusNotFound, "manifest or profile not loaded")
		return
	}

	var targetService *proto.ProviderService
	for i := range manifest.Profile.Services {
		if manifest.Profile.Services[i].ID == id {
			targetService = &manifest.Profile.Services[i]
			break
		}
	}
	if targetService == nil {
		writeError(w, http.StatusNotFound, "service not found in profile")
		return
	}

	switch targetService.Type {
	case "proxy_picker":
		sourceURL, _ := targetService.Config["source_url"].(string)
		if sourceURL == "" {
			writeError(w, http.StatusBadRequest, "invalid proxy_picker config: missing source_url")
			return
		}
		// Return proxy_picker result deep_link
		templateStr, _ := targetService.Config["output"].(map[string]any)["template"].(string)
		if templateStr == "" {
			templateStr = "tg://proxy?server={host}&port={port}&secret={secret}"
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"service_id": id,
			"type":       "proxy_picker",
			"status":     "resolved",
			"deep_link":  templateStr,
		})
	case "value_display":
		endpoint, _ := targetService.Config["endpoint"].(string)
		writeJSON(w, http.StatusOK, map[string]any{
			"service_id": id,
			"type":       "value_display",
			"value":      "Active",
			"endpoint":   endpoint,
		})
	default:
		writeJSON(w, http.StatusOK, map[string]any{
			"service_id": id,
			"type":       targetService.Type,
			"status":     "ok",
		})
	}
}
