package state

import (
	"encoding/base64"
	"maps"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/subs"
)

// A parsed REALITY/Vision subscription row must produce a sing-box outbound
// that actually carries reality, vision flow and the camouflage SNI. Without
// these the daemon reports a healthy config and the tunnel handshake is rejected
// by the server.
func TestVisionServerBuildsRealityOutbound(t *testing.T) {
	const uri = "vless://ac13138b-9b17-460d-a0dc-fcec65a2b9e4@5.175.188.152:8443" +
		"?encryption=none&flow=xtls-rprx-vision&type=tcp&security=reality" +
		"&sni=www.apple.com&fp=chrome" +
		"&pbk=InKO5I2xu3niJAoMYeybkUelaGJoNdjrOzs6q8CbUAg&sid=4b2f1a9c7d3e5a10" +
		"#Vision"

	payload := []byte(base64.StdEncoding.EncodeToString([]byte(uri + "\n")))
	res, err := subs.Parse("sub-vision", payload)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(res.Servers) != 1 {
		t.Fatalf("expected 1 server, got %d", len(res.Servers))
	}

	out, err := outboundFor(res.Servers[0])
	if err != nil {
		t.Fatalf("outboundFor: %v", err)
	}
	if out["type"] != "vless" {
		t.Fatalf("type = %v", out["type"])
	}
	if out["flow"] != "xtls-rprx-vision" {
		t.Fatalf("vision flow missing: %v", out["flow"])
	}
	tls, _ := out["tls"].(map[string]any)
	if tls == nil {
		t.Fatal("tls block missing")
	}
	if tls["server_name"] != "www.apple.com" {
		t.Fatalf("server_name = %v", tls["server_name"])
	}
	reality, _ := tls["reality"].(map[string]any)
	if reality == nil || reality["enabled"] != true {
		t.Fatalf("reality block missing: %v", maps.Keys(tls))
	}
	if reality["public_key"] != "InKO5I2xu3niJAoMYeybkUelaGJoNdjrOzs6q8CbUAg" {
		t.Fatalf("public_key = %v", reality["public_key"])
	}
	if reality["short_id"] != "4b2f1a9c7d3e5a10" {
		t.Fatalf("short_id = %v", reality["short_id"])
	}
	if out["server_port"] != 8443 {
		t.Fatalf("port = %v", out["server_port"])
	}
	if proto.ProtoVLESS != res.Servers[0].Protocol {
		t.Fatalf("protocol = %v", res.Servers[0].Protocol)
	}
}
