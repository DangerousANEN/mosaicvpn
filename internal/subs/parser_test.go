package subs_test

import (
	"encoding/base64"
	"strings"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/subs"
)

func TestDetectAndParseSingbox(t *testing.T) {
	payload := []byte(`{
		"outbounds": [
			{"type": "vless", "tag": "tokyo-vless", "server": "1.2.3.4", "server_port": 443, "uuid": "ab"},
			{"type": "hysteria2", "tag": "amst-hy2", "server": "5.6.7.8", "server_port": 8443, "password": "p"},
			{"type": "selector", "tag": "auto"},
			{"type": "block", "tag": "block"}
		]
	}`)
	if got := subs.Detect(payload); got != proto.FormatSingbox {
		t.Fatalf("expected singbox, got %s", got)
	}
	res, err := subs.Parse("sub-1", payload)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(res.Servers) != 2 {
		t.Fatalf("expected 2 real servers, got %d", len(res.Servers))
	}
	if res.Servers[0].Protocol != proto.ProtoVLESS || res.Servers[0].Address != "1.2.3.4" || res.Servers[0].Port != 443 {
		t.Fatalf("vless server wrong: %+v", res.Servers[0])
	}
	if res.Servers[1].Protocol != proto.ProtoHysteria2 || res.Servers[1].Port != 8443 {
		t.Fatalf("hy2 server wrong: %+v", res.Servers[1])
	}
}

func TestParseV2RayBase64(t *testing.T) {
	body := strings.Join([]string{
		"vless://ab-cd-ef@1.2.3.4:443?security=reality&flow=xtls-rprx-vision&pbk=k&sid=s#Tokyo%20Premium",
		"hysteria2://pw@5.6.7.8:8443/?obfs=salamander&obfs-password=op&sni=foo.com#Amsterdam",
		"ss://" + base64.StdEncoding.EncodeToString([]byte("aes-256-gcm:hunter2")) + "@9.9.9.9:8388#Singapore",
	}, "\n")
	enc := base64.StdEncoding.EncodeToString([]byte(body))
	res, err := subs.Parse("sub-2", []byte(enc))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if res.Format != proto.FormatV2RayB64 {
		t.Fatalf("expected v2ray-base64 format, got %s", res.Format)
	}
	if len(res.Servers) != 3 {
		t.Fatalf("expected 3 servers, got %d", len(res.Servers))
	}
	if res.Servers[0].Protocol != proto.ProtoVLESS || res.Servers[0].Tag != "reality" {
		t.Fatalf("vless wrong: %+v", res.Servers[0])
	}
	if res.Servers[0].Name != "Tokyo Premium" {
		t.Fatalf("vless name wrong: %q", res.Servers[0].Name)
	}
	if res.Servers[1].Protocol != proto.ProtoHysteria2 || res.Servers[1].Tag != "salamander" {
		t.Fatalf("hy2 wrong: %+v", res.Servers[1])
	}
	if res.Servers[2].Protocol != proto.ProtoShadowsocks || res.Servers[2].Tag != "aes-256-gcm" {
		t.Fatalf("ss wrong: %+v", res.Servers[2])
	}
}

func TestParseClashYAML(t *testing.T) {
	payload := []byte(`
proxies:
  - {name: "tokyo", type: vless, server: 1.2.3.4, port: 443, uuid: ab, flow: xtls-rprx-vision}
  - {name: "amst", type: hysteria2, server: 5.6.7.8, port: 8443, password: pw}
  - {name: "sg", type: ss, server: 9.9.9.9, port: 8388, cipher: aes-256-gcm, password: hunter2}
proxy-groups:
  - {name: "auto", type: url-test}
`)
	if got := subs.Detect(payload); got != proto.FormatClash {
		t.Fatalf("expected clash, got %s", got)
	}
	res, err := subs.Parse("sub-3", payload)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(res.Servers) != 3 {
		t.Fatalf("expected 3 servers, got %d", len(res.Servers))
	}
}

func TestParseSIP008(t *testing.T) {
	payload := []byte(`{
		"version": 1,
		"servers": [
			{"id": "abc", "remarks": "Tokyo", "server": "1.2.3.4", "server_port": 8388, "method": "aes-256-gcm", "password": "p"},
			{"remarks": "Singapore", "server": "9.9.9.9", "server_port": 8388, "method": "chacha20-ietf-poly1305", "password": "q"}
		]
	}`)
	if got := subs.Detect(payload); got != proto.FormatSIP008 {
		t.Fatalf("expected sip008, got %s", got)
	}
	res, err := subs.Parse("sub-4", payload)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(res.Servers) != 2 {
		t.Fatalf("expected 2, got %d", len(res.Servers))
	}
	if res.Servers[0].ID != "abc" {
		t.Fatalf("expected provider-supplied ID 'abc', got %q", res.Servers[0].ID)
	}
}

func TestDeterministicIDs(t *testing.T) {
	payload := []byte("vless://ab@1.2.3.4:443#x")
	r1, _ := subs.Parse("subA", payload)
	r2, _ := subs.Parse("subA", payload)
	if r1.Servers[0].ID != r2.Servers[0].ID {
		t.Fatalf("expected stable ID across parses, got %q vs %q", r1.Servers[0].ID, r2.Servers[0].ID)
	}
}

func TestUnknownFormat(t *testing.T) {
	if _, err := subs.Parse("sub-x", []byte("definitely not a subscription")); err == nil {
		t.Fatal("expected error for non-subscription payload")
	}
}
