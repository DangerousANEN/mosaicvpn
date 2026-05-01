package subs_test

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"encoding/binary"
	"strings"
	"testing"

	"github.com/DangerousANEN/mosaicvpn/internal/proto"
	"github.com/DangerousANEN/mosaicvpn/internal/subs"
)

const wgConf = `[Interface]
PrivateKey = aGVsbG8td29ybGQta2V5LWZvci10ZXN0aW5nLW9ubHkx
Address = 10.0.0.2/32, fd42::2/128
DNS = 1.1.1.1
MTU = 1280
Jc = 4
Jmin = 50
Jmax = 1000
S1 = 86
S2 = 574
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = cHViLWtleS1mb3ItdGVzdC1vbmx5LWZpeGVkLWxlbmd0aGVk
PresharedKey = cHNrLWtleS1mb3ItdGVzdC1vbmx5LWZpeGVkLWxlbmd0aGVk
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = vpn.example.com:51820
PersistentKeepalive = 25
`

func TestDetectAndParseWireGuardConf(t *testing.T) {
	if got := subs.Detect([]byte(wgConf)); got != proto.FormatWireGuardConf {
		t.Fatalf("expected wireguard-conf, got %s", got)
	}
	res, err := subs.ParseWithName("sub-wg", []byte(wgConf), "Tokyo Free")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(res.Servers) != 1 {
		t.Fatalf("expected 1 server, got %d", len(res.Servers))
	}
	srv := res.Servers[0]
	if srv.Protocol != proto.ProtoAmneziaWG {
		t.Errorf("protocol = %s, want %s", srv.Protocol, proto.ProtoAmneziaWG)
	}
	if srv.Address != "vpn.example.com" || srv.Port != 51820 {
		t.Errorf("endpoint = %s:%d, want vpn.example.com:51820", srv.Address, srv.Port)
	}
	if srv.Name != "Tokyo Free" {
		t.Errorf("name = %q, want Tokyo Free", srv.Name)
	}
	for _, k := range []string{"jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4"} {
		if _, ok := srv.Raw[k]; !ok {
			t.Errorf("missing AWG key %s in raw", k)
		}
	}
	if _, ok := srv.Raw["private_key"]; !ok {
		t.Error("missing private_key")
	}
	if _, ok := srv.Raw["peer_public_key"]; !ok {
		t.Error("missing peer_public_key")
	}
	if _, ok := srv.Raw["pre_shared_key"]; !ok {
		t.Error("missing pre_shared_key")
	}
	la, ok := srv.Raw["local_address"].([]any)
	if !ok || len(la) != 2 {
		t.Errorf("local_address = %#v, want 2-element slice", srv.Raw["local_address"])
	}
}

func TestParseWireGuardConfBareMinimum(t *testing.T) {
	conf := `[Interface]
PrivateKey = abc
[Peer]
PublicKey = xyz
Endpoint = 127.0.0.1:1234
`
	res, err := subs.ParseWithName("s", []byte(conf), "")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(res.Servers) != 1 {
		t.Fatalf("expected 1 server, got %d", len(res.Servers))
	}
	if !strings.HasPrefix(res.Servers[0].Name, "wg://") {
		t.Errorf("default name = %q, want wg:// prefix", res.Servers[0].Name)
	}
}

func TestParseWireGuardConfMissingPeer(t *testing.T) {
	conf := `[Interface]
PrivateKey = abc
`
	if _, err := subs.ParseWireGuardConf("s", []byte(conf), ""); err == nil {
		t.Fatal("expected error on missing [Peer]")
	}
}

func TestSuggestNameFromFilename(t *testing.T) {
	cases := map[string]string{
		"my-server.conf":          "my-server",
		"/tmp/Tokyo Free.conf":    "Tokyo Free",
		"sub.YAML":                "sub",
		"":                        "",
		"plain":                   "plain",
	}
	for in, want := range cases {
		if got := subs.SuggestNameFromFilename(in); got != want {
			t.Errorf("SuggestNameFromFilename(%q) = %q, want %q", in, got, want)
		}
	}
}

// encodeAmneziaVPN reproduces the AmneziaVPN export framing: 4-byte
// big-endian length header + zlib-compressed JSON, base64-urlsafe,
// `vpn://` prefix, no padding.  Used only to build test fixtures.
func encodeAmneziaVPN(t *testing.T, jsonBytes []byte) string {
	t.Helper()
	var buf bytes.Buffer
	zw := zlib.NewWriter(&buf)
	if _, err := zw.Write(jsonBytes); err != nil {
		t.Fatalf("zlib write: %v", err)
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("zlib close: %v", err)
	}
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, uint32(len(jsonBytes)))
	encoded := base64.URLEncoding.WithPadding(base64.NoPadding).EncodeToString(append(header, buf.Bytes()...))
	return "vpn://" + encoded
}

func TestDetectAndParseAmneziaVPN(t *testing.T) {
	json := []byte(`{
  "description": "AmneziaFree RU",
  "hostName": "1.2.3.4",
  "containers": [
    {
      "container": "amnezia-awg",
      "awg": {
        "last_config": "[Interface]\nPrivateKey = priv-1\n\n[Peer]\nPublicKey = pub-1\nEndpoint = 1.2.3.4:51820\n"
      }
    }
  ]
}`)
	token := encodeAmneziaVPN(t, json)
	if got := subs.Detect([]byte(token)); got != proto.FormatAmneziaVPN {
		t.Fatalf("detect = %s, want amnezia-vpn", got)
	}
	res, err := subs.ParseWithName("sub-amn", []byte(token), "")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(res.Servers) != 1 {
		t.Fatalf("expected 1 server, got %d", len(res.Servers))
	}
	if res.Servers[0].Name != "AmneziaFree RU" {
		t.Errorf("name = %q, want AmneziaFree RU", res.Servers[0].Name)
	}
	if res.Servers[0].Address != "1.2.3.4" || res.Servers[0].Port != 51820 {
		t.Errorf("endpoint = %s:%d", res.Servers[0].Address, res.Servers[0].Port)
	}
}

func TestParseAmneziaVPNAPIHandle(t *testing.T) {
	json := []byte(`{
  "config_version": 1,
  "api_endpoint": "https://example.com/api/v1/request/awg/",
  "protocol": "awg",
  "name": "X",
  "api_key": "k"
}`)
	token := encodeAmneziaVPN(t, json)
	_, err := subs.ParseAmneziaVPN("sub-h", []byte(token), "")
	if err == nil {
		t.Fatal("expected error on API-handle-only token")
	}
	if !strings.Contains(err.Error(), "API handle") {
		t.Errorf("error = %v, want API-handle hint", err)
	}
}
