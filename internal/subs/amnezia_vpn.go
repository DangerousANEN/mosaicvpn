package subs

// ParseAmneziaVPN decodes an AmneziaVPN `vpn://...` token and lifts
// out every WireGuard / AmneziaWG container inside.
//
// Format (reverse-engineered from amnezia-client and the upstream
// reference decoder at https://github.com/andr13/amnezia-config-decoder):
//
//	vpn://<urlsafe-base64-no-padding>
//
// The decoded bytes are either:
//
//	- a 4-byte big-endian length header followed by zlib-compressed JSON, or
//	- raw JSON (when the producer skipped compression).
//
// The JSON itself comes in two flavours:
//
//  1. "Full" server export — a `{containers: [{container: "amnezia-awg",
//     awg: {last_config: "<wg-conf>"} }]}` shape. We extract every
//     `last_config` we can reach and pipe it through ParseWireGuardConf.
//
//  2. "API" handle — `{config_version: 1.0, api_endpoint: "...",
//     protocol: "awg", api_key: "..."}`. These require a live HTTP
//     round-trip against the publisher's API to obtain the actual
//     wg config; that is out of scope for an offline parser, so we
//     surface a descriptive error pointing the user at the right path
//     ("paste the .conf instead, or use the AmneziaVPN client to
//     unwrap this URL first").
//
// AmneziaWG-specific obfuscation parameters travel intact because
// `last_config` is a verbatim wg-quick payload — they round-trip
// through ParseWireGuardConf without any special handling here.

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/DangerousANEN/mosaicvpn/internal/proto"
)

// LooksLikeAmneziaVPN reports whether the payload starts with the
// `vpn://` scheme prefix that AmneziaVPN's export uses.
func LooksLikeAmneziaVPN(payload []byte) bool {
	s := strings.TrimSpace(string(payload))
	return strings.HasPrefix(strings.ToLower(s), "vpn://")
}

// ParseAmneziaVPN decodes a `vpn://...` token and returns one Server
// per AmneziaWG container in the config.  `name` is an advisory
// display name shared by every server (the JSON's own `description`
// or `name` field will override it when present).
func ParseAmneziaVPN(subID string, payload []byte, name string) ([]proto.Server, error) {
	token := strings.TrimSpace(string(payload))
	if !LooksLikeAmneziaVPN(payload) {
		return nil, errors.New("amnezia-vpn: missing vpn:// prefix")
	}
	token = token[len("vpn://"):]

	jsonBytes, err := decodeAmneziaPayload(token)
	if err != nil {
		return nil, fmt.Errorf("amnezia-vpn: decode: %w", err)
	}

	// Try the "full export" shape first.  When the JSON only
	// contains an API handle the loop below produces zero servers
	// and we fall through to the explicit error.
	servers, err := extractAmneziaContainers(subID, jsonBytes, name)
	if err != nil {
		return nil, err
	}
	if len(servers) == 0 {
		// API-handle form?  Surface a useful error rather than a
		// silent no-op.
		var probe struct {
			APIEndpoint string `json:"api_endpoint"`
			Protocol    string `json:"protocol"`
		}
		if err := json.Unmarshal(jsonBytes, &probe); err == nil && probe.APIEndpoint != "" {
			return nil, fmt.Errorf("amnezia-vpn: this token is an API handle (%s, protocol=%q); the actual WireGuard config is fetched at runtime by the AmneziaVPN client. Use the official client to unwrap it once, then paste the resulting .conf into Mosaic", probe.APIEndpoint, probe.Protocol)
		}
		return nil, errors.New("amnezia-vpn: no AmneziaWG containers found in token")
	}
	return servers, nil
}

// decodeAmneziaPayload reverses base64-urlsafe(+ optional zlib) and
// returns the raw JSON bytes.
func decodeAmneziaPayload(token string) ([]byte, error) {
	// urlsafe-base64 without padding — pad to a multiple of 4.
	token = strings.TrimSpace(token)
	if pad := len(token) % 4; pad != 0 {
		token += strings.Repeat("=", 4-pad)
	}
	raw, err := base64.URLEncoding.DecodeString(token)
	if err != nil {
		// fall back to standard alphabet for tolerant inputs
		raw, err = base64.StdEncoding.DecodeString(token)
		if err != nil {
			return nil, fmt.Errorf("not base64: %w", err)
		}
	}
	if len(raw) < 4 {
		return nil, errors.New("payload too short")
	}

	// Try the "len-header + zlib" framing.  When that fails we
	// assume the bytes are plain JSON (some older versions of the
	// AmneziaVPN client emit uncompressed exports).
	declared := binary.BigEndian.Uint32(raw[:4])
	zr, err := zlib.NewReader(bytes.NewReader(raw[4:]))
	if err == nil {
		defer zr.Close()
		out, err := io.ReadAll(zr)
		if err == nil {
			if declared > 0 && uint32(len(out)) != declared {
				// Length mismatch — fall back to raw rather than
				// loudly fail; some encoders skip the header.
				return raw, nil
			}
			return out, nil
		}
	}

	// Plain JSON?
	if bytes.HasPrefix(bytes.TrimSpace(raw), []byte("{")) {
		return raw, nil
	}
	// Last resort: maybe the whole thing is zlib without a header.
	if zr2, err := zlib.NewReader(bytes.NewReader(raw)); err == nil {
		defer zr2.Close()
		if out, err := io.ReadAll(zr2); err == nil {
			return out, nil
		}
	}
	return nil, errors.New("payload is neither raw JSON nor zlib-compressed")
}

// extractAmneziaContainers walks the JSON structure produced by
// AmneziaVPN's exportController.cpp and produces one Server per
// AmneziaWG / WireGuard container.
func extractAmneziaContainers(subID string, jsonBytes []byte, fallbackName string) ([]proto.Server, error) {
	var doc map[string]any
	if err := json.Unmarshal(jsonBytes, &doc); err != nil {
		return nil, fmt.Errorf("amnezia-vpn: bad JSON: %w", err)
	}
	host, _ := doc["hostName"].(string)
	descr, _ := doc["description"].(string)
	if descr == "" {
		descr, _ = doc["name"].(string)
	}
	if descr == "" {
		descr = strings.TrimSpace(fallbackName)
	}

	containers, _ := doc["containers"].([]any)
	if len(containers) == 0 {
		return nil, nil
	}

	var out []proto.Server
	for ci, raw := range containers {
		c, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		// Each container holds protocol-specific blocks under
		// keys like "awg" / "wireguard" / "openvpn" / "shadowsocks".
		// We only know how to lift WireGuard / AmneziaWG.
		for _, key := range []string{"awg", "wireguard"} {
			block, ok := c[key].(map[string]any)
			if !ok {
				continue
			}
			conf, _ := block["last_config"].(string)
			if conf == "" {
				continue
			}
			// `last_config` is sometimes itself a JSON-encoded
			// blob with `{"config":"<conf>"}` instead of the raw
			// INI.  Try both.
			confBytes := []byte(conf)
			if strings.HasPrefix(strings.TrimSpace(conf), "{") {
				var nested struct {
					Config string `json:"config"`
				}
				if err := json.Unmarshal(confBytes, &nested); err == nil && nested.Config != "" {
					confBytes = []byte(nested.Config)
				}
			}
			name := descr
			if name == "" && host != "" {
				name = host
			}
			if name == "" {
				name = fmt.Sprintf("amnezia[%d]", ci)
			}
			servers, err := ParseWireGuardConf(subID, confBytes, name)
			if err != nil {
				return nil, fmt.Errorf("amnezia-vpn: container %d (%s): %w", ci, key, err)
			}
			out = append(out, servers...)
		}
	}
	return out, nil
}
