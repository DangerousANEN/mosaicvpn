// Package subs parses subscription payloads in the four supported formats:
// sing-box JSON, Clash YAML, v2ray base64 (vless/vmess/ss/hysteria2 URI
// lists), and SIP008.
//
// The Parse entry point auto-detects the format. Individual ParseXxx
// functions can be invoked directly when the format is known.
package subs

import (
	"crypto/sha1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	"github.com/DangerousANEN/mosaic/internal/proto"
)

// ErrUnknownFormat is returned when no parser recognises the payload.
var ErrUnknownFormat = errors.New("subscription payload format not recognised")

// Result is the outcome of parsing a subscription payload.
type Result struct {
	Format  proto.Format
	Servers []proto.Server
}

// Detect returns the most likely format for the payload, or FormatUnknown.
func Detect(payload []byte) proto.Format {
	trimmed := strings.TrimSpace(string(payload))
	if trimmed == "" {
		return proto.FormatUnknown
	}

	// JSON-ish detection
	if trimmed[0] == '{' || trimmed[0] == '[' {
		if looksLikeSingbox(trimmed) {
			return proto.FormatSingbox
		}
		if looksLikeSIP008(trimmed) {
			return proto.FormatSIP008
		}
		// Some sing-box subscription formats share the SIP008 envelope but
		// not the proxy fields; default to sing-box if neither matched.
	}

	// YAML-ish detection (Clash)
	if strings.Contains(trimmed, "\nproxies:") || strings.HasPrefix(trimmed, "proxies:") ||
		strings.Contains(trimmed, "\nproxy-groups:") {
		return proto.FormatClash
	}

	// v2ray base64: a single base64 blob whose decoded form is a list of URIs
	if isLikelyBase64(trimmed) {
		dec, err := decodeBase64Loose(trimmed)
		if err == nil && containsKnownURI(string(dec)) {
			return proto.FormatV2RayB64
		}
	}

	// Already-decoded URI list (some providers serve it directly).
	if containsKnownURI(trimmed) {
		return proto.FormatV2RayB64
	}

	return proto.FormatUnknown
}

// Parse auto-detects the format and parses the payload. Server IDs are
// derived deterministically from their canonical form so that re-fetching a
// subscription does not churn IDs.
func Parse(subID string, payload []byte) (Result, error) {
	format := Detect(payload)
	switch format {
	case proto.FormatSingbox:
		servers, err := ParseSingbox(subID, payload)
		return Result{Format: format, Servers: servers}, err
	case proto.FormatV2RayB64:
		servers, err := ParseV2RayBase64(subID, payload)
		return Result{Format: format, Servers: servers}, err
	case proto.FormatClash:
		servers, err := ParseClash(subID, payload)
		return Result{Format: format, Servers: servers}, err
	case proto.FormatSIP008:
		servers, err := ParseSIP008(subID, payload)
		return Result{Format: format, Servers: servers}, err
	default:
		return Result{Format: proto.FormatUnknown}, ErrUnknownFormat
	}
}

// ParseAs forces a specific format. Useful when the user explicitly specifies
// the subscription type.
func ParseAs(subID string, payload []byte, format proto.Format) (Result, error) {
	switch format {
	case proto.FormatSingbox:
		s, err := ParseSingbox(subID, payload)
		return Result{Format: format, Servers: s}, err
	case proto.FormatV2RayB64:
		s, err := ParseV2RayBase64(subID, payload)
		return Result{Format: format, Servers: s}, err
	case proto.FormatClash:
		s, err := ParseClash(subID, payload)
		return Result{Format: format, Servers: s}, err
	case proto.FormatSIP008:
		s, err := ParseSIP008(subID, payload)
		return Result{Format: format, Servers: s}, err
	}
	return Result{Format: proto.FormatUnknown}, ErrUnknownFormat
}

// ----- helpers -------------------------------------------------------------

func serverID(subID string, fields ...string) string {
	h := sha1.New()
	h.Write([]byte(subID))
	for _, f := range fields {
		h.Write([]byte{0})
		h.Write([]byte(f))
	}
	return hex.EncodeToString(h.Sum(nil))[:16]
}

func isLikelyBase64(s string) bool {
	if len(s) < 16 {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'A' && r <= 'Z':
		case r >= 'a' && r <= 'z':
		case r >= '0' && r <= '9':
		case r == '+' || r == '/' || r == '-' || r == '_' || r == '=' || r == '\n' || r == '\r' || r == ' ':
		default:
			return false
		}
	}
	return true
}

func decodeBase64Loose(s string) ([]byte, error) {
	s = strings.NewReplacer("\n", "", "\r", "", " ", "").Replace(s)
	if v, err := base64.StdEncoding.DecodeString(padBase64(s)); err == nil {
		return v, nil
	}
	if v, err := base64.URLEncoding.DecodeString(padBase64(s)); err == nil {
		return v, nil
	}
	if v, err := base64.RawStdEncoding.DecodeString(s); err == nil {
		return v, nil
	}
	if v, err := base64.RawURLEncoding.DecodeString(s); err == nil {
		return v, nil
	}
	return nil, fmt.Errorf("not base64")
}

func padBase64(s string) string {
	if m := len(s) % 4; m != 0 {
		s += strings.Repeat("=", 4-m)
	}
	return s
}

var knownSchemes = []string{
	"vless://", "vmess://", "ss://", "ssr://", "hysteria2://", "hy2://",
	"naive+https://", "naive+quic://", "trojan://", "wireguard://",
}

func containsKnownURI(s string) bool {
	low := strings.ToLower(s)
	for _, scheme := range knownSchemes {
		if strings.Contains(low, scheme) {
			return true
		}
	}
	return false
}

func looksLikeSingbox(s string) bool {
	// A sing-box config has top-level "outbounds" or the v2ray-style
	// "outbounds": [...] inside an object. Cheap substring check.
	return strings.Contains(s, `"outbounds"`)
}

func looksLikeSIP008(s string) bool {
	return strings.Contains(s, `"servers"`) &&
		(strings.Contains(s, `"method"`) || strings.Contains(s, `"password"`))
}

// portFromString parses a port given as either int or string.
func portFromString(v any) int {
	switch t := v.(type) {
	case float64:
		return int(t)
	case int:
		return t
	case json.Number:
		p, _ := t.Int64()
		return int(p)
	case string:
		p, _ := strconv.Atoi(t)
		return p
	}
	return 0
}

// urlBareHost returns u.Host minus port.
func urlBareHost(u *url.URL) string {
	h := u.Host
	if i := strings.LastIndex(h, ":"); i >= 0 {
		return h[:i]
	}
	return h
}

func hostPort(u *url.URL) (string, int) {
	host := urlBareHost(u)
	port := 0
	if p := u.Port(); p != "" {
		port, _ = strconv.Atoi(p)
	}
	return host, port
}
