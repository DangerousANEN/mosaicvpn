package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestBotLinkVerifierSuccess(t *testing.T) {
	var gotCode string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/link/redeem" {
			t.Errorf("path = %q, want /api/link/redeem", r.URL.Path)
		}
		if r.Method != http.MethodPost {
			t.Errorf("method = %q, want POST", r.Method)
		}
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		gotCode = body["code"]
		writeJSON(w, http.StatusOK, LinkVerification{
			TelegramID:   777,
			Username:     "nikita",
			SessionToken: "tok-abc",
		})
	}))
	defer srv.Close()

	v := NewBotLinkVerifier(srv.URL)
	res, err := v.Verify(context.Background(), "AB23CD45")
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if gotCode != "AB23CD45" {
		t.Errorf("code sent = %q, want AB23CD45", gotCode)
	}
	if res.TelegramID != 777 || res.Username != "nikita" || res.SessionToken != "tok-abc" {
		t.Errorf("unexpected result: %+v", res)
	}
}

func TestBotLinkVerifierStatusMapping(t *testing.T) {
	cases := []struct {
		status int
		want   error
	}{
		{http.StatusNotFound, errLinkNotFound},
		{http.StatusGone, errLinkExpired},
		{http.StatusConflict, errLinkUsed},
		{http.StatusTooManyRequests, errLinkAttempts},
	}
	for _, tc := range cases {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(tc.status)
		}))
		v := NewBotLinkVerifier(srv.URL)
		_, err := v.Verify(context.Background(), "X")
		if !errors.Is(err, tc.want) {
			t.Errorf("status %d: err = %v, want %v", tc.status, err, tc.want)
		}
		srv.Close()
	}
}

// A 5xx from the bot is an outage. Reporting it as a bad code would send the
// user off to request replacement codes that cannot possibly work.
func TestBotLinkVerifierServerErrorIsUnavailableNotRejection(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	v := NewBotLinkVerifier(srv.URL)
	_, err := v.Verify(context.Background(), "X")
	if !errors.Is(err, ErrVerifierUnavailable) {
		t.Fatalf("err = %v, want ErrVerifierUnavailable", err)
	}
	for _, bad := range []error{errLinkNotFound, errLinkExpired, errLinkUsed} {
		if errors.Is(err, bad) {
			t.Errorf("outage misreported as %v", bad)
		}
	}
}

func TestBotLinkVerifierUnreachableHost(t *testing.T) {
	// Closed port: the connection is refused immediately.
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	url := srv.URL
	srv.Close()

	v := NewBotLinkVerifier(url)
	v.Client = &http.Client{Timeout: 2 * time.Second}
	if _, err := v.Verify(context.Background(), "X"); !errors.Is(err, ErrVerifierUnavailable) {
		t.Fatalf("err = %v, want ErrVerifierUnavailable", err)
	}
}

func TestBotLinkVerifierEmptyBaseURL(t *testing.T) {
	v := &BotLinkVerifier{}
	if _, err := v.Verify(context.Background(), "X"); !errors.Is(err, ErrVerifierUnavailable) {
		t.Fatalf("err = %v, want ErrVerifierUnavailable", err)
	}
}

// A 200 with a garbage body must not be accepted as a successful link, or the
// daemon would store an account with telegram_id 0.
func TestBotLinkVerifierRejectsMalformedOK(t *testing.T) {
	for _, body := range []string{`not json`, `{}`, `{"telegram_id":0}`} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(body))
		}))
		v := NewBotLinkVerifier(srv.URL)
		if _, err := v.Verify(context.Background(), "X"); !errors.Is(err, ErrVerifierUnavailable) {
			t.Errorf("body %q: err = %v, want ErrVerifierUnavailable", body, err)
		}
		srv.Close()
	}
}

func TestBotLinkVerifierBuildsDirectFeedURL(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, LinkVerification{
			TelegramID:  777,
			Username:    "nikita",
			DirectToken: "opaque+/ token",
		})
	}))
	defer srv.Close()

	res, err := NewBotLinkVerifier(srv.URL).Verify(context.Background(), "AB23CD45")
	if err != nil {
		t.Fatalf("Verify() error = %v", err)
	}
	want := srv.URL + "/api/direct/singbox?token=opaque%2B%2F+token"
	if res.DirectFeedURL != want {
		t.Fatalf("DirectFeedURL = %q, want %q", res.DirectFeedURL, want)
	}
	if strings.Contains(res.DirectFeedURL, "telegram") {
		t.Fatalf("DirectFeedURL must not contain a Telegram identifier: %q", res.DirectFeedURL)
	}
}

func TestBotLinkVerifierHonoursContextCancel(t *testing.T) {
	block := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-block
	}))
	defer func() { close(block); srv.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	v := NewBotLinkVerifier(srv.URL)
	if _, err := v.Verify(ctx, "X"); !errors.Is(err, ErrVerifierUnavailable) {
		t.Fatalf("err = %v, want ErrVerifierUnavailable", err)
	}
}
