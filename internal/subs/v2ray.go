package subs

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	"github.com/DangerousANEN/mosaic/internal/proto"
)

// ParseV2RayBase64 parses a base64-encoded list of share-URIs (or, if the
// payload is already decoded, a plain newline-separated list).
func ParseV2RayBase64(subID string, payload []byte) ([]proto.Server, error) {
	body := strings.TrimSpace(string(payload))
	if !containsKnownURI(body) {
		dec, err := decodeBase64Loose(body)
		if err != nil {
			return nil, fmt.Errorf("v2ray-base64: not base64 and no URIs: %w", err)
		}
		body = string(dec)
	}

	var out []proto.Server
	for _, raw := range strings.Split(body, "\n") {
		raw = strings.TrimSpace(raw)
		if raw == "" || strings.HasPrefix(raw, "#") {
			continue
		}
		s, err := parseShareURI(subID, raw)
		if err != nil || s.Protocol == "" {
			continue
		}
		out = append(out, s)
	}
	return out, nil
}

func parseShareURI(subID, raw string) (proto.Server, error) {
	low := strings.ToLower(raw)
	switch {
	case strings.HasPrefix(low, "vless://"):
		return parseVLESS(subID, raw)
	case strings.HasPrefix(low, "vmess://"):
		return parseVMess(subID, raw)
	case strings.HasPrefix(low, "ss://"):
		return parseSS(subID, raw)
	case strings.HasPrefix(low, "hysteria2://") || strings.HasPrefix(low, "hy2://"):
		return parseHysteria2(subID, raw)
	case strings.HasPrefix(low, "naive+https://") || strings.HasPrefix(low, "naive+quic://"):
		return parseNaive(subID, raw)
	}
	return proto.Server{}, fmt.Errorf("unknown scheme: %s", raw)
}

func parseVLESS(subID, raw string) (proto.Server, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return proto.Server{}, err
	}
	host, port := hostPort(u)
	uuid := u.User.Username()
	q := u.Query()
	name := decodeFragment(u.Fragment, fmt.Sprintf("vless://%s:%d", host, port))

	flow := q.Get("flow")
	tag := flow
	if sec := q.Get("security"); sec == "reality" {
		tag = "reality"
	}

	s := proto.Server{
		ID:             serverID(subID, "vless", host, fmt.Sprint(port), uuid),
		Name:           name,
		Protocol:       proto.ProtoVLESS,
		Address:        host,
		Port:           port,
		Tag:            tag,
		SubscriptionID: subID,
		Raw: map[string]any{
			"uuid":       uuid,
			"flow":       flow,
			"security":   q.Get("security"),
			"sni":        q.Get("sni"),
			"public_key": q.Get("pbk"),
			"short_id":   q.Get("sid"),
			"fingerprint": q.Get("fp"),
			"network":    q.Get("type"),
			"path":       q.Get("path"),
			"host":       q.Get("host"),
		},
	}
	return s, nil
}

func parseVMess(subID, raw string) (proto.Server, error) {
	body := strings.TrimPrefix(raw, "vmess://")
	body = strings.TrimPrefix(body, "VMESS://")
	dec, err := decodeBase64Loose(body)
	if err != nil {
		return proto.Server{}, err
	}
	var v map[string]any
	if err := json.Unmarshal(dec, &v); err != nil {
		return proto.Server{}, err
	}
	host, _ := v["add"].(string)
	port := portFromString(v["port"])
	uuid, _ := v["id"].(string)
	name, _ := v["ps"].(string)
	if name == "" {
		name = fmt.Sprintf("vmess://%s:%d", host, port)
	}
	// vmess maps to vless in our model with tls-mode tag
	s := proto.Server{
		ID:             serverID(subID, "vmess", host, fmt.Sprint(port), uuid),
		Name:           name,
		Protocol:       proto.ProtoVLESS,
		Address:        host,
		Port:           port,
		Tag:            fmt.Sprint(v["scy"]),
		SubscriptionID: subID,
		Raw:            v,
	}
	return s, nil
}

func parseSS(subID, raw string) (proto.Server, error) {
	// ss://method:password@host:port#name (plain)
	// ss://base64(method:password)@host:port#name (legacy)
	// ss://base64(method:password@host:port)#name (very legacy)
	body := strings.TrimPrefix(raw, "ss://")
	body = strings.TrimPrefix(body, "SS://")

	frag := ""
	if i := strings.Index(body, "#"); i >= 0 {
		frag = body[i+1:]
		body = body[:i]
	}

	// Modern SIP002: userinfo is base64(method:password); host:port is plain.
	if at := strings.LastIndex(body, "@"); at >= 0 {
		userinfo := body[:at]
		hostPart := body[at+1:]
		if dec, err := decodeBase64Loose(userinfo); err == nil {
			userinfo = string(dec)
		}
		method, pass, _ := strings.Cut(userinfo, ":")
		host, portStr, _ := strings.Cut(hostPart, ":")
		port, _ := strconv.Atoi(portStr)
		name := decodeFragment(frag, fmt.Sprintf("ss://%s:%d", host, port))
		return proto.Server{
			ID:             serverID(subID, "ss", host, portStr, method, pass),
			Name:           name,
			Protocol:       proto.ProtoShadowsocks,
			Address:        host,
			Port:           port,
			Tag:            method,
			SubscriptionID: subID,
			Raw: map[string]any{
				"method":   method,
				"password": pass,
			},
		}, nil
	}

	// Legacy: whole thing is base64(method:password@host:port)
	dec, err := decodeBase64Loose(body)
	if err != nil {
		return proto.Server{}, err
	}
	full := string(dec)
	at := strings.LastIndex(full, "@")
	if at < 0 {
		return proto.Server{}, fmt.Errorf("ss: malformed legacy URI")
	}
	method, pass, _ := strings.Cut(full[:at], ":")
	host, portStr, _ := strings.Cut(full[at+1:], ":")
	port, _ := strconv.Atoi(portStr)
	name := decodeFragment(frag, fmt.Sprintf("ss://%s:%d", host, port))
	return proto.Server{
		ID:             serverID(subID, "ss", host, portStr, method, pass),
		Name:           name,
		Protocol:       proto.ProtoShadowsocks,
		Address:        host,
		Port:           port,
		Tag:            method,
		SubscriptionID: subID,
		Raw: map[string]any{
			"method":   method,
			"password": pass,
		},
	}, nil
}

func parseHysteria2(subID, raw string) (proto.Server, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return proto.Server{}, err
	}
	host, port := hostPort(u)
	password := u.User.Username()
	if password == "" {
		password = u.User.String()
	}
	q := u.Query()
	name := decodeFragment(u.Fragment, fmt.Sprintf("hy2://%s:%d", host, port))
	return proto.Server{
		ID:             serverID(subID, "hy2", host, fmt.Sprint(port), password),
		Name:           name,
		Protocol:       proto.ProtoHysteria2,
		Address:        host,
		Port:           port,
		Tag:            q.Get("obfs"),
		SubscriptionID: subID,
		Raw: map[string]any{
			"password":     password,
			"obfs":         q.Get("obfs"),
			"obfs_password": q.Get("obfs-password"),
			"sni":          q.Get("sni"),
			"insecure":     q.Get("insecure") == "1",
		},
	}, nil
}

func parseNaive(subID, raw string) (proto.Server, error) {
	// naive+https://user:pass@host:port?...
	body := strings.TrimPrefix(raw, "naive+")
	u, err := url.Parse(body)
	if err != nil {
		return proto.Server{}, err
	}
	host, port := hostPort(u)
	user := u.User.Username()
	pass, _ := u.User.Password()
	name := decodeFragment(u.Fragment, fmt.Sprintf("naive://%s:%d", host, port))
	return proto.Server{
		ID:             serverID(subID, "naive", host, fmt.Sprint(port), user),
		Name:           name,
		Protocol:       proto.ProtoNaive,
		Address:        host,
		Port:           port,
		SubscriptionID: subID,
		Raw: map[string]any{
			"username": user,
			"password": pass,
			"scheme":   u.Scheme, // https or quic
		},
	}, nil
}

func decodeFragment(frag, fallback string) string {
	if frag == "" {
		return fallback
	}
	if dec, err := url.QueryUnescape(frag); err == nil && dec != "" {
		return dec
	}
	if dec, err := base64.RawURLEncoding.DecodeString(frag); err == nil {
		return string(dec)
	}
	return frag
}
