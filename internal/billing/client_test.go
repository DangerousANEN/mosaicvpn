package billing

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

// --- Remnawave stub ---

func remnawaveStub(users map[int64]UserProfile, traffic map[string]TrafficInfo) *httptest.Server {
	mux := http.NewServeMux()

	// GET /api/users/by-telegram-id/{telegramID}
	mux.HandleFunc("/api/users/by-telegram-id/", func(w http.ResponseWriter, r *http.Request) {
		idStr := strings.TrimPrefix(r.URL.Path, "/api/users/by-telegram-id/")
		id, err := strconv.ParseInt(idStr, 10, 64)
		if err != nil {
			http.Error(w, "bad id", 400)
			return
		}
		u, ok := users[id]
		if !ok {
			http.NotFound(w, r)
			return
		}
		// Remnawave wraps single objects in {"response": [{...}]}
		raw := map[string]any{
			"uuid":              u.UUID,
			"shortUuid":         u.ShortUUID,
			"username":          u.Username,
			"status":            u.Status,
			"telegramId":        u.TelegramID,
			"tag":               u.Tag,
			"email":             u.Email,
			"trafficLimitBytes": u.TrafficLimitBytes,
			"expireAt":          u.ExpireAt.Format(time.RFC3339),
			"description":       u.Description,
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"response": []any{raw}})
	})

	// GET /api/users/by-uuid/{uuid}/traffic
	mux.HandleFunc("/api/users/by-uuid/", func(w http.ResponseWriter, r *http.Request) {
		path := strings.TrimPrefix(r.URL.Path, "/api/users/by-uuid/")
		if !strings.HasSuffix(path, "/traffic") {
			http.NotFound(w, r)
			return
		}
		uuid := strings.TrimSuffix(path, "/traffic")
		t, ok := traffic[uuid]
		if !ok {
			http.NotFound(w, r)
			return
		}
		raw := map[string]any{
			"usedTrafficBytes":      t.UsedTrafficBytes,
			"lastConnectedNodeUuid": t.LastConnectedNode,
		}
		if t.OnlineAt != nil {
			raw["onlineAt"] = t.OnlineAt.Format(time.RFC3339)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"response": raw})
	})

	return httptest.NewServer(mux)
}

// --- CryptoBot stub ---

func cryptoBotStub() *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/createInvoice", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"result": map[string]any{
				"invoice_id": 12345,
				"pay_url":    "https://pay.crypt.bot/invoice123",
				"amount":     "5.00",
				"asset":      "USDT",
			},
		})
	})
	mux.HandleFunc("/api/getInvoices", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"result": map[string]any{
				"items": []map[string]any{
					{"invoice_id": 12345, "status": "paid"},
				},
			},
		})
	})
	return httptest.NewServer(mux)
}

// --- helpers ---

func mkCfg(remnawaveURL, remnawaveTok, cryptoURL, cryptoTok string) Config {
	return Config{
		Remnawave: RemnawaveConfig{BaseURL: remnawaveURL, APIToken: remnawaveTok},
		CryptoBot: CryptoBotConfig{BaseURL: cryptoURL, APIToken: cryptoTok},
	}
}

// --- tests ---

func TestGetUserByTelegramID_NotFound(t *testing.T) {
	srv := remnawaveStub(nil, nil)
	defer srv.Close()
	c := NewClient(mkCfg(srv.URL, "tok", "", ""))
	_, err := c.GetUserByTelegramID(context.Background(), 999)
	if err == nil {
		t.Fatal("expected error for missing user")
	}
}

func TestGetUserByTelegramID_Present(t *testing.T) {
	user := UserProfile{
		UUID:       "uuid-123",
		Username:   "alice",
		TelegramID: 42,
		ExpireAt:   time.Now().Add(72 * time.Hour),
	}
	srv := remnawaveStub(map[int64]UserProfile{42: user}, nil)
	defer srv.Close()
	c := NewClient(mkCfg(srv.URL, "tok", "", ""))
	got, err := c.GetUserByTelegramID(context.Background(), 42)
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if got.Username != "alice" {
		t.Fatalf("username mismatch: %s", got.Username)
	}
	if got.UUID != "uuid-123" {
		t.Fatalf("uuid mismatch: %s", got.UUID)
	}
}

func TestGetUserTraffic(t *testing.T) {
	traffic := TrafficInfo{UsedTrafficBytes: 123456789}
	srv := remnawaveStub(nil, map[string]TrafficInfo{"uuid-123": traffic})
	defer srv.Close()
	c := NewClient(mkCfg(srv.URL, "tok", "", ""))
	got, err := c.GetUserTraffic(context.Background(), "uuid-123")
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if got.UsedTrafficBytes != 123456789 {
		t.Fatalf("traffic mismatch: %d", got.UsedTrafficBytes)
	}
}

func TestCreateInvoice(t *testing.T) {
	srv := cryptoBotStub()
	defer srv.Close()
	c := NewClient(mkCfg("", "", srv.URL, "tok"))
	inv, err := c.CreateInvoice(context.Background(), 5.0, "test")
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if inv.InvoiceID != 12345 {
		t.Fatalf("invoice id: %d", inv.InvoiceID)
	}
	if inv.PayURL == "" {
		t.Fatal("empty pay url")
	}
}

func TestCheckInvoice(t *testing.T) {
	srv := cryptoBotStub()
	defer srv.Close()
	c := NewClient(mkCfg("", "", srv.URL, "tok"))
	status, err := c.CheckInvoice(context.Background(), 12345)
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if status != "paid" {
		t.Fatalf("status: %s", status)
	}
}

func TestUpdateConfig(t *testing.T) {
	c := NewClient(Config{})
	newCfg := mkCfg("http://example.com", "t", "", "")
	c.UpdateConfig(newCfg)
	if c.cfg.Remnawave.BaseURL != "http://example.com" {
		t.Fatal("config not updated")
	}
}

func TestGetUserByTelegramID_ZeroID(t *testing.T) {
	c := NewClient(mkCfg("http://example.com", "tok", "", ""))
	_, err := c.GetUserByTelegramID(context.Background(), 0)
	if err != ErrUserNotFound {
		t.Fatalf("want ErrUserNotFound, got %v", err)
	}
}

func TestCreateInvoice_ZeroAmount(t *testing.T) {
	c := NewClient(mkCfg("", "", "http://example.com", "tok"))
	_, err := c.CreateInvoice(context.Background(), 0, "test")
	if err == nil {
		t.Fatal("want error for zero amount")
	}
}
