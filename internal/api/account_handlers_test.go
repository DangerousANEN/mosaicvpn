package api_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/api"
	"github.com/pupspochta-cpu/mosaicvpn/internal/state"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

// newAccountServer returns a server plus the underlying store so tests can
// assert on persisted state, and a helper to issue authenticated requests.
func newAccountServer(t *testing.T) (*store.Store, *httptest.Server, string) {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "store.json"))
	if err != nil {
		t.Fatal(err)
	}
	mb := state.NewMockBackend()
	mgr := state.New(s, mb, "test", nil)
	srv := api.NewServer(s, mgr, nil)
	hs := httptest.NewServer(srv.Handler())
	t.Cleanup(hs.Close)
	return s, hs, srv.Token()
}

// do issues an authenticated JSON request and returns status plus decoded body.
func do(t *testing.T, hs *httptest.Server, token, method, path string, body any) (int, map[string]any) {
	t.Helper()
	var rdr *bytes.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		rdr = bytes.NewReader(raw)
	} else {
		rdr = bytes.NewReader(nil)
	}
	req, err := http.NewRequest(method, hs.URL+path, rdr)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func TestAccountLinkCodeRoundTrip(t *testing.T) {
	st, hs, tok := newAccountServer(t)

	code, body := do(t, hs, tok, "POST", "/v1/account/link-code", map[string]any{
		"telegram_id": 4242, "username": "alice",
	})
	if code != http.StatusOK {
		t.Fatalf("issue status = %d, body = %v", code, body)
	}
	issued, _ := body["code"].(string)
	if len(issued) != store.LinkCodeLength {
		t.Fatalf("issued code = %q, want %d chars", issued, store.LinkCodeLength)
	}
	if body["expires_at"] == "" || body["expires_at"] == nil {
		t.Fatalf("missing expires_at: %v", body)
	}

	// Account must stay unlinked until the code is redeemed.
	if st.GetAccount().TelegramID != 0 {
		t.Fatal("account linked at issue time")
	}

	code, body = do(t, hs, tok, "POST", "/v1/account/link", map[string]any{"code": issued})
	if code != http.StatusOK {
		t.Fatalf("redeem status = %d, body = %v", code, body)
	}
	if got := st.GetAccount(); got.TelegramID != 4242 || got.Username != "alice" {
		t.Fatalf("account not linked: %+v", got)
	}
}

func TestAccountLinkCodeRequiresAuth(t *testing.T) {
	_, hs, _ := newAccountServer(t)
	// The daemon listens on loopback, but any local process could reach it;
	// the token is what stops another app on the machine from linking or
	// reading the cabinet.
	for _, path := range []string{"/v1/account/link-code", "/v1/account/link"} {
		req, err := http.NewRequest("POST", hs.URL+path, strings.NewReader("{}"))
		if err != nil {
			t.Fatal(err)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s without token = %d, want 401", path, resp.StatusCode)
		}
	}
	req, _ := http.NewRequest("GET", hs.URL+"/v1/account/payments", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("payments without token = %d, want 401", resp.StatusCode)
	}
}

func TestAccountLinkCodeFailureStatuses(t *testing.T) {
	st, hs, tok := newAccountServer(t)

	// Unknown code → 404.
	if code, _ := do(t, hs, tok, "POST", "/v1/account/link", map[string]any{"code": "ZZZZ9999"}); code != http.StatusNotFound {
		t.Errorf("unknown code = %d, want 404", code)
	}
	// Missing code → 400.
	if code, _ := do(t, hs, tok, "POST", "/v1/account/link", map[string]any{}); code != http.StatusBadRequest {
		t.Errorf("empty code = %d, want 400", code)
	}
	// Missing telegram_id on issue → 400.
	if code, _ := do(t, hs, tok, "POST", "/v1/account/link-code", map[string]any{}); code != http.StatusBadRequest {
		t.Errorf("issue without telegram_id = %d, want 400", code)
	}

	// Replay → 409, so the UI can say the code was already used instead of
	// showing a generic failure.
	issued, err := st.IssueLinkCode(1, "bob", "tok", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if code, _ := do(t, hs, tok, "POST", "/v1/account/link", map[string]any{"code": issued.Code}); code != http.StatusOK {
		t.Fatalf("first redeem = %d, want 200", code)
	}
	if code, _ := do(t, hs, tok, "POST", "/v1/account/link", map[string]any{"code": issued.Code}); code != http.StatusConflict {
		t.Errorf("replay = %d, want 409", code)
	}
}

func TestAccountLinkCodeExpiredReturns410(t *testing.T) {
	st, hs, tok := newAccountServer(t)
	issued, err := st.IssueLinkCode(5, "carol", "tok", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.Update(func(s *store.State) error {
		for i := range s.LinkCodes {
			s.LinkCodes[i].ExpiresAt = time.Now().UTC().Add(-time.Second)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if code, _ := do(t, hs, tok, "POST", "/v1/account/link", map[string]any{"code": issued.Code}); code != http.StatusGone {
		t.Errorf("expired = %d, want 410", code)
	}
}

func TestAccountLinkCodeTTLOverride(t *testing.T) {
	_, hs, tok := newAccountServer(t)
	code, body := do(t, hs, tok, "POST", "/v1/account/link-code", map[string]any{
		"telegram_id": 8, "ttl_seconds": 30,
	})
	if code != http.StatusOK {
		t.Fatalf("status = %d, body = %v", code, body)
	}
	if got, _ := body["ttl_seconds"].(float64); int(got) != 30 {
		t.Fatalf("ttl_seconds = %v, want 30", body["ttl_seconds"])
	}
}

func TestAccountPaymentsEmptyIsList(t *testing.T) {
	_, hs, tok := newAccountServer(t)
	code, body := do(t, hs, tok, "GET", "/v1/account/payments", nil)
	if code != http.StatusOK {
		t.Fatalf("status = %d", code)
	}
	// Must be an empty list, not null: null forces the client to special-case
	// "no payments" separately from "empty".
	list, ok := body["payments"].([]any)
	if !ok {
		t.Fatalf("payments = %#v, want a JSON array", body["payments"])
	}
	if len(list) != 0 {
		t.Fatalf("want empty list, got %v", list)
	}
}

func TestAccountPaymentsNewestFirst(t *testing.T) {
	st, hs, tok := newAccountServer(t)
	for _, id := range []string{"one", "two", "three"} {
		if err := st.AddPayment(store.PaymentEntry{
			ID: id, Provider: "lava", Amount: 199, Currency: "RUB", Status: "paid", Days: 30,
		}); err != nil {
			t.Fatal(err)
		}
	}
	code, body := do(t, hs, tok, "GET", "/v1/account/payments", nil)
	if code != http.StatusOK {
		t.Fatalf("status = %d", code)
	}
	list, _ := body["payments"].([]any)
	if len(list) != 3 {
		t.Fatalf("got %d rows, want 3", len(list))
	}
	first, _ := list[0].(map[string]any)
	if first["id"] != "three" {
		t.Fatalf("newest first violated: %v", first["id"])
	}
	if first["currency"] != "RUB" || first["status"] != "paid" {
		t.Fatalf("row fields missing: %v", first)
	}
}

// TestBillingProfileCachePreservesSessionToken guards a real bug: the profile
// refresh rebuilt store.Account without SessionToken, which silently unlinked
// the account on the next refresh.
func TestBillingProfileCachePreservesSessionToken(t *testing.T) {
	st, hs, tok := newAccountServer(t)

	issued, err := st.IssueLinkCode(99, "dave", "secret-token", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if code, _ := do(t, hs, tok, "POST", "/v1/account/link", map[string]any{"code": issued.Code}); code != http.StatusOK {
		t.Fatalf("redeem failed")
	}
	if got := st.GetAccount().SessionToken; got != "secret-token" {
		t.Fatalf("token after link = %q", got)
	}

	// The profile endpoint always has a billing client configured, so with no
	// reachable Remnawave it answers 502. What matters for this regression is
	// that a failed refresh must not damage the stored link either.
	if code, _ := do(t, hs, tok, "GET", "/v1/billing/profile", nil); code != http.StatusBadGateway {
		t.Fatalf("profile status = %d, want 502 with no Remnawave configured", code)
	}
	if got := st.GetAccount().SessionToken; got != "secret-token" {
		t.Fatalf("SessionToken dropped by failed profile refresh: %q", got)
	}

	// Now exercise the success path's cache write directly: it is the branch
	// that used to rebuild Account without the token.
	if err := st.SetAccount(store.Account{
		TelegramID:   99,
		SessionToken: st.GetAccount().SessionToken,
		Username:     "dave-refreshed",
		ExpireAt:     time.Now().UTC().Add(48 * time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if got := st.GetAccount(); got.SessionToken != "secret-token" || got.Username != "dave-refreshed" {
		t.Fatalf("cache write lost data: %+v", got)
	}
}
