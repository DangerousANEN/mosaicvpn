package subs_test

import (
	"encoding/base64"
	"fmt"
	"strings"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/subs"
)

// The published "Напрямую (Vision)" host must parse into a usable VLESS/reality
// server. A parser that silently drops the route (or its transport) leaves the
// client with an empty cabinet even though the server side is healthy.
func TestParsePublishedVisionRoute(t *testing.T) {
	const uri = "vless://ac13138b-9b17-460d-a0dc-fcec65a2b9e4@5.175.188.152:8443" +
		"?encryption=none&flow=xtls-rprx-vision&type=tcp&security=reality" +
		"&sni=www.apple.com&fp=chrome" +
		"&pbk=InKO5I2xu3niJAoMYeybkUelaGJoNdjrOzs6q8CbUAg&sid=4b2f1a9c7d3e5a10" +
		"#%D0%9D%D0%B0%D0%BF%D1%80%D1%8F%D0%BC%D1%83%D1%8E%20(Vision)"

	payload := []byte(base64.StdEncoding.EncodeToString([]byte(uri + "\n")))
	res, err := subs.Parse("sub-vision", payload)
	if err != nil {
		t.Fatalf("subscription parse failed: %v", err)
	}
	if len(res.Servers) != 1 {
		t.Fatalf("expected 1 server, got %d", len(res.Servers))
	}
	server := res.Servers[0]
	if server.Protocol != proto.ProtoVLESS {
		t.Fatalf("protocol = %v, want vless", server.Protocol)
	}
	if server.Port != 8443 {
		t.Fatalf("port = %d, want 8443", server.Port)
	}
	if server.Tag != "reality" {
		t.Fatalf("tag = %q, want reality", server.Tag)
	}
	raw := server.Raw
	if raw == nil {
		t.Fatal("raw transport parameters were dropped")
	}
	serialized := strings.ToLower(strings.TrimSpace(fmt.Sprint(raw)))
	if !strings.Contains(serialized, "reality") && !strings.Contains(serialized, server.Address) {
		t.Fatalf("route lost its connection parameters: %v", serialized)
	}
}
