package geoip

import "testing"

func TestIsoFromName(t *testing.T) {
	cases := map[string]string{
		"DE-VLESS-WS":         "DE",
		"de-vless-ws":         "DE",
		"CN-VLESS-XHTTP":      "CN",
		"[US] VLESS":          "US",
		"[us] VLESS":          "US",
		"US.vless":            "US",
		"US_main":             "US",
		"US main":             "US",
		"VPS1-Hysteria2":      "",
		"Max-VLESS":           "",
		"VM02-Naive":          "",
		"vless":               "",
		"":                    "",
		"X":                   "",
		"XX-fake":             "", // XX is not a valid ISO code
		"\u26a0\ufe0f-warning": "",
	}
	for name, want := range cases {
		if got := IsoFromName(name); got != want {
			t.Errorf("IsoFromName(%q) = %q, want %q", name, got, want)
		}
	}
}
