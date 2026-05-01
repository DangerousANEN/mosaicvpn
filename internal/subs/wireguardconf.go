package subs

// ParseWireGuardConf reads a WireGuard / AmneziaWG INI configuration
// (the `[Interface]` / `[Peer]` `.conf` format that the official
// `wg-quick` and AmneziaVPN clients write) and returns a single
// proto.Server with proto.ProtoAmneziaWG.
//
// We do not pull in a third-party INI parser — the wg-quick syntax is
// trivial enough that a hand-rolled tokenizer is shorter and produces
// better error messages.  Lines starting with `#` or `;` are
// comments; section headers are `[Name]`; everything else is
// `key = value` (the `=` may be flanked by arbitrary whitespace and
// values may contain `=` characters themselves, so we split on the
// first `=` only).
//
// AmneziaWG-specific obfuscation parameters (`Jc`, `Jmin`, `Jmax`,
// `S1`, `S2`, `H1`..`H4`) live inside the `[Interface]` block and are
// promoted into `Server.Raw` under their lowercase canonical names so
// that `internal/state/singbox_backend.go::outboundFor` (which
// already speaks both clash flat keys and sing-box nested form) can
// pick them up unchanged.

import (
	"errors"
	"fmt"
	"net"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/DangerousANEN/mosaicvpn/internal/proto"
)

// ParseWireGuardConf parses a WireGuard / AmneziaWG `.conf` payload.
// `name` is an advisory display name (typically the file basename
// without extension); pass an empty string and the resulting Server
// will be named `wg://<endpoint>`.
func ParseWireGuardConf(subID string, payload []byte, name string) ([]proto.Server, error) {
	iface, peer, err := parseWGINI(payload)
	if err != nil {
		return nil, err
	}
	host, port, err := splitEndpoint(peer["endpoint"])
	if err != nil {
		return nil, fmt.Errorf("wireguard-conf: %w", err)
	}
	priv := iface["privatekey"]
	if priv == "" {
		return nil, errors.New("wireguard-conf: [Interface] PrivateKey missing")
	}
	pub := peer["publickey"]
	if pub == "" {
		return nil, errors.New("wireguard-conf: [Peer] PublicKey missing")
	}

	display := strings.TrimSpace(name)
	if display == "" {
		display = fmt.Sprintf("wg://%s:%d", host, port)
	}

	raw := map[string]any{
		"private_key":     priv,
		"peer_public_key": pub,
	}
	if v := peer["presharedkey"]; v != "" {
		raw["pre_shared_key"] = v
	}
	if v := iface["mtu"]; v != "" {
		raw["mtu"] = v
	}
	if v := iface["address"]; v != "" {
		// `Address` may be a comma-separated list of CIDRs.  The
		// outbound builder accepts []string under `local_address`.
		out := []any{}
		for _, p := range strings.Split(v, ",") {
			p = strings.TrimSpace(p)
			if p != "" {
				out = append(out, p)
			}
		}
		if len(out) > 0 {
			raw["local_address"] = out
		}
	}
	if v := peer["allowedips"]; v != "" {
		raw["allowed_ips"] = v
	}
	// AmneziaWG obfuscation parameters live in [Interface].  Copy
	// every one we recognise as a string — outboundFor will parse
	// them with strconv.Atoi.
	for _, k := range []string{"jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4"} {
		if v := iface[k]; v != "" {
			raw[k] = v
		}
	}

	srv := proto.Server{
		ID:             serverID(subID, "wgconf", host, fmt.Sprint(port), pub),
		SubscriptionID: subID,
		Name:           display,
		Protocol:       proto.ProtoAmneziaWG,
		Address:        host,
		Port:           port,
		Raw:            raw,
	}
	return []proto.Server{srv}, nil
}

// SuggestNameFromFilename strips a directory prefix and extension to
// produce a friendly subscription / server name.  Empty input returns
// an empty string.  This is exported so the API layer can reuse it
// when accepting file uploads.
func SuggestNameFromFilename(path string) string {
	base := filepath.Base(strings.TrimSpace(path))
	if base == "" || base == "." || base == "/" {
		return ""
	}
	for _, ext := range []string{".conf", ".json", ".yaml", ".yml", ".txt"} {
		if strings.HasSuffix(strings.ToLower(base), ext) {
			base = base[:len(base)-len(ext)]
			break
		}
	}
	return base
}

// LooksLikeWireGuardConf returns true when the payload appears to be
// a WireGuard / AmneziaWG INI document.  Used by Detect.
func LooksLikeWireGuardConf(payload []byte) bool {
	low := strings.ToLower(string(payload))
	return strings.Contains(low, "[interface]") &&
		strings.Contains(low, "[peer]") &&
		strings.Contains(low, "privatekey")
}

// parseWGINI tokenises the conf into two flat maps keyed by
// lowercased key names.  All keys are normalised by stripping spaces
// and lowercasing, which lets us match `Jc`, `JC`, `jc`, etc.
// uniformly.  When the same key appears more than once in a section
// the last occurrence wins (matches wg-quick behaviour).  Lines
// inside unknown sections are silently ignored — some
// AmneziaVPN-exported configs contain `[Connect]` or similar
// metadata blocks we do not care about.
func parseWGINI(payload []byte) (iface, peer map[string]string, err error) {
	iface = map[string]string{}
	peer = map[string]string{}
	section := ""
	for _, raw := range strings.Split(string(payload), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") ||
			strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			continue
		}
		eq := strings.Index(line, "=")
		if eq < 0 {
			continue
		}
		k := strings.ToLower(strings.TrimSpace(line[:eq]))
		k = strings.ReplaceAll(k, "_", "")
		k = strings.ReplaceAll(k, "-", "")
		v := strings.TrimSpace(line[eq+1:])
		switch section {
		case "interface":
			iface[k] = v
		case "peer":
			peer[k] = v
		}
	}
	if len(iface) == 0 || len(peer) == 0 {
		return nil, nil, errors.New("wireguard-conf: missing [Interface] or [Peer] section")
	}
	return iface, peer, nil
}

// splitEndpoint parses a `host:port` string from a [Peer] Endpoint
// directive.  IPv6 endpoints come in the bracket form `[::1]:51820`
// — we delegate to net.SplitHostPort which understands that.
func splitEndpoint(ep string) (string, int, error) {
	ep = strings.TrimSpace(ep)
	if ep == "" {
		return "", 0, errors.New("[Peer] Endpoint missing")
	}
	host, portStr, err := net.SplitHostPort(ep)
	if err != nil {
		return "", 0, fmt.Errorf("bad endpoint %q: %w", ep, err)
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port <= 0 || port > 65535 {
		return "", 0, fmt.Errorf("bad endpoint port %q", portStr)
	}
	return host, port, nil
}
