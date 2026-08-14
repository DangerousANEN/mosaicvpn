package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestGetAccountServiceUsesTokenQuery(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/billing/profile" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.String())
		}
		if got := r.URL.Query().Get("token"); got != "session-token" {
			t.Fatalf("token = %q", got)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"status": "active"})
	}))
	defer server.Close()

	var response struct {
		Status string `json:"status"`
	}
	verifier := NewBotLinkVerifier(server.URL)
	if err := verifier.getAccountService(context.Background(), "/api/billing/profile", "session-token", &response); err != nil {
		t.Fatal(err)
	}
	if response.Status != "active" {
		t.Fatalf("status = %q", response.Status)
	}
}

func TestCallAccountServiceSendsTokenInBody(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/account/freeze" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.String())
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["token"] != "client-token" {
			t.Fatalf("token body = %#v", body["token"])
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
	}))
	defer server.Close()

	var response struct {
		OK bool `json:"ok"`
	}
	verifier := NewBotLinkVerifier(server.URL)
	if err := verifier.callAccountService(context.Background(), http.MethodPost, "/api/account/freeze", "client-token", nil, &response); err != nil {
		t.Fatal(err)
	}
	if !response.OK {
		t.Fatal("ok response expected")
	}
}

func TestAccountServiceMapsUnauthorizedWithoutLeakingToken(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"invalid or expired session"}`))
	}))
	defer server.Close()

	verifier := NewBotLinkVerifier(server.URL)
	err := verifier.getAccountService(context.Background(), "/api/billing/profile", "do-not-log", nil)
	remote, ok := err.(*AccountServiceError)
	if !ok || remote.Status != http.StatusUnauthorized || remote.Code != "invalid or expired session" {
		t.Fatalf("unexpected error: %#v", err)
	}
	if got := err.Error(); got == "do-not-log" {
		t.Fatal("token leaked into error")
	}
}
