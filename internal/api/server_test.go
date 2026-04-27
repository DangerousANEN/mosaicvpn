package api_test

import (
	"context"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/api"
	"github.com/pupspochta-cpu/mosaicvpn/internal/apiclient"
	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/state"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

func newTestServer(t *testing.T, fetcher api.Fetcher) (*api.Server, *apiclient.Client, *httptest.Server) {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "store.json"))
	if err != nil {
		t.Fatal(err)
	}
	mb := state.NewMockBackend()
	mgr := state.New(s, mb, "test")
	srv := api.NewServer(s, mgr, fetcher)

	hs := httptest.NewServer(srv.Handler())
	t.Cleanup(hs.Close)

	host, portStr, _ := strings.Cut(strings.TrimPrefix(hs.URL, "http://"), ":")
	port, _ := strconv.Atoi(portStr)
	c := apiclient.New(host, port, srv.Token())
	return srv, c, hs
}

func TestStatusEndpointAuth(t *testing.T) {
	srv, c, hs := newTestServer(t, nil)
	_ = srv

	// good token
	st, err := c.Status(context.Background())
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if st.State != proto.StateDisconnected {
		t.Fatalf("expected disconnected, got %s", st.State)
	}

	// bad token
	bad := apiclient.New(strings.TrimPrefix(hs.URL, "http://"), 0, "wrong")
	_ = bad
	// Direct HTTP without auth header:
	resp, err := hs.Client().Get(hs.URL + "/v1/status")
	if err != nil {
		t.Fatalf("raw get: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatalf("expected 401 without auth, got %d", resp.StatusCode)
	}
}

// TestCORSPreflight ensures the daemon answers CORS preflight requests
// without first being rejected by the bearer-token check. The Tauri
// renderer (and `vite dev`) sit at a different origin than the loopback
// API and rely on this to talk to the daemon.
func TestCORSPreflight(t *testing.T) {
	_, _, hs := newTestServer(t, nil)

	req, err := http.NewRequest(http.MethodOptions, hs.URL+"/v1/status", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Origin", "http://localhost:1420")
	req.Header.Set("Access-Control-Request-Method", "GET")
	req.Header.Set("Access-Control-Request-Headers", "authorization,content-type")

	resp, err := hs.Client().Do(req)
	if err != nil {
		t.Fatalf("preflight: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("preflight status: got %d, want 204", resp.StatusCode)
	}
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != "http://localhost:1420" {
		t.Fatalf("Allow-Origin: got %q, want echo of request origin", got)
	}
	allowHeaders := resp.Header.Get("Access-Control-Allow-Headers")
	for _, want := range []string{"Authorization", "Content-Type"} {
		if !strings.Contains(allowHeaders, want) {
			t.Fatalf("Allow-Headers %q missing %q", allowHeaders, want)
		}
	}
	if got := resp.Header.Get("Access-Control-Allow-Methods"); !strings.Contains(got, "GET") {
		t.Fatalf("Allow-Methods missing GET: %q", got)
	}
}

// TestCORSAuthenticatedRequestEchoesOrigin ensures that real (non-OPTIONS)
// requests also carry the Access-Control-Allow-Origin header so the
// renderer can read the response body.
func TestCORSAuthenticatedRequestEchoesOrigin(t *testing.T) {
	srv, _, hs := newTestServer(t, nil)

	req, err := http.NewRequest(http.MethodGet, hs.URL+"/v1/status", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Origin", "tauri://localhost")
	req.Header.Set("Authorization", "Bearer "+srv.Token())

	resp, err := hs.Client().Do(req)
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status: got %d, want 200", resp.StatusCode)
	}
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != "tauri://localhost" {
		t.Fatalf("Allow-Origin: got %q, want echo of request origin", got)
	}
}

func TestSubscriptionLifecycle(t *testing.T) {
	payload := []byte("vless://abc@1.2.3.4:443?security=reality&flow=v#JP\n")
	encoded := []byte(base64.StdEncoding.EncodeToString(payload))
	fetcher := func(ctx context.Context, url string) ([]byte, string, error) {
		if !strings.HasPrefix(url, "https://example") {
			return nil, "", errors.New("bad url")
		}
		return encoded, "", nil
	}
	_, c, _ := newTestServer(t, fetcher)

	sub, err := c.AddSubscription(context.Background(), proto.AddSubscriptionRequest{
		URL:  "https://example.com/sub",
		Name: "Example",
	})
	if err != nil {
		t.Fatalf("add: %v", err)
	}
	if sub.Format != proto.FormatV2RayB64 {
		t.Fatalf("expected v2ray format, got %s", sub.Format)
	}
	if sub.ServerCount != 1 {
		t.Fatalf("expected 1 server, got %d", sub.ServerCount)
	}

	servers, err := c.Servers(context.Background(), sub.ID)
	if err != nil {
		t.Fatalf("servers: %v", err)
	}
	if len(servers) != 1 || servers[0].Protocol != proto.ProtoVLESS {
		t.Fatalf("unexpected servers: %+v", servers)
	}

	// Connect to the discovered server.
	st, err := c.Connect(context.Background(), servers[0].ID)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	if st.State != proto.StateConnected {
		t.Fatalf("expected connected, got %s", st.State)
	}

	if _, err := c.Disconnect(context.Background()); err != nil {
		t.Fatalf("disconnect: %v", err)
	}

	if err := c.DeleteSubscription(context.Background(), sub.ID); err != nil {
		t.Fatalf("delete sub: %v", err)
	}

	subs, err := c.Subscriptions(context.Background())
	if err != nil {
		t.Fatalf("list subs: %v", err)
	}
	if len(subs) != 0 {
		t.Fatalf("expected no subs after delete, got %d", len(subs))
	}
}

func TestRulesLifecycle(t *testing.T) {
	_, c, _ := newTestServer(t, nil)

	r1, err := c.AddRule(context.Background(), proto.Rule{
		Name: "Block ads", Enabled: true, Action: proto.ActionBlock,
		Match: proto.Match{GeoSite: []string{"category-ads"}},
	})
	if err != nil {
		t.Fatalf("add rule: %v", err)
	}
	r2, err := c.AddRule(context.Background(), proto.Rule{
		Name: "LAN direct", Enabled: true, Action: proto.ActionDirect,
		Match: proto.Match{IPCIDR: []string{"192.168.0.0/16"}},
	})
	if err != nil {
		t.Fatalf("add rule 2: %v", err)
	}
	rules, err := c.Rules(context.Background())
	if err != nil {
		t.Fatalf("rules: %v", err)
	}
	if len(rules) != 2 {
		t.Fatalf("expected 2 rules, got %d", len(rules))
	}

	out, err := c.ReorderRules(context.Background(), []string{r2.ID, r1.ID})
	if err != nil {
		t.Fatalf("reorder: %v", err)
	}
	if out[0].ID != r2.ID || out[0].Priority != 1 {
		t.Fatalf("expected r2 first with priority 1, got %+v", out[0])
	}

	if err := c.DeleteRule(context.Background(), r1.ID); err != nil {
		t.Fatalf("delete: %v", err)
	}
	rules, _ = c.Rules(context.Background())
	if len(rules) != 1 || rules[0].ID != r2.ID {
		t.Fatalf("expected only r2 left, got %+v", rules)
	}
}

func TestPrefsRoundTrip(t *testing.T) {
	_, c, _ := newTestServer(t, nil)

	p, err := c.Prefs(context.Background())
	if err != nil {
		t.Fatalf("prefs: %v", err)
	}
	if !p.KillSwitch {
		t.Fatal("expected default kill-switch on")
	}
	p.KillSwitch = false
	p.MTU = 1280
	out, err := c.SetPrefs(context.Background(), p)
	if err != nil {
		t.Fatalf("set prefs: %v", err)
	}
	if out.MTU != 1280 || out.KillSwitch {
		t.Fatalf("prefs not updated: %+v", out)
	}
}

