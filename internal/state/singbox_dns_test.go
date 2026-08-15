package state

import "testing"

func TestSingBoxDNSServerParsesUDPURL(t *testing.T) {
	entry := singBoxDNSServer("dns-primary", "udp://77.88.8.8", "")
	if entry["type"] != "udp" || entry["server"] != "77.88.8.8" || entry["server_port"] != 53 {
		t.Fatalf("UDP entry = %#v; want udp 77.88.8.8:53", entry)
	}
	if _, ok := entry["detour"]; ok {
		t.Fatalf("direct resolver unexpectedly has detour: %#v", entry)
	}
}

func TestSingBoxDNSServerParsesDoHURL(t *testing.T) {
	entry := singBoxDNSServer("dns-proxied", "https://1.1.1.1/dns-query", "proxy")
	if entry["type"] != "https" || entry["server"] != "1.1.1.1" || entry["server_port"] != 443 {
		t.Fatalf("DoH entry = %#v; want https 1.1.1.1:443", entry)
	}
	if entry["path"] != "/dns-query" || entry["detour"] != "proxy" {
		t.Fatalf("DoH path/detour = %#v; want /dns-query via proxy", entry)
	}
}

func TestSingBoxDNSServerAcceptsPlainAddress(t *testing.T) {
	entry := singBoxDNSServer("dns-primary", "8.8.8.8", "")
	if entry["type"] != "udp" || entry["server"] != "8.8.8.8" || entry["server_port"] != 53 {
		t.Fatalf("plain endpoint entry = %#v; want udp 8.8.8.8:53", entry)
	}
}

func TestPreferredListenerPort(t *testing.T) {
	cases := []struct {
		address  string
		fallback int
		want     int
	}{
		{"127.0.0.1:1080", 2080, 1080},
		{"[::1]:1081", 2081, 1081},
		{"invalid", 2080, 2080},
		{"127.0.0.1:70000", 2080, 2080},
	}
	for _, tc := range cases {
		if got := preferredListenerPort(tc.address, tc.fallback); got != tc.want {
			t.Errorf("preferredListenerPort(%q, %d) = %d; want %d", tc.address, tc.fallback, got, tc.want)
		}
	}
}
