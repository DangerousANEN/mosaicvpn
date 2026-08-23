package elevate

import "testing"

func TestRequired(t *testing.T) {
	cases := map[string]bool{
		"tun":     true,
		"proxy":   false,
		"":        false,
		"unknown": false,
	}
	for mode, want := range cases {
		if got := Required(mode); got != want {
			t.Errorf("Required(%q) = %v, want %v", mode, got, want)
		}
	}
}

func TestEnsureProxyModeNeverBlocks(t *testing.T) {
	if err := Ensure("proxy"); err != nil {
		t.Fatalf("Ensure(proxy) = %v, want nil", err)
	}
}

func TestSentinelIsDistinct(t *testing.T) {
	if ErrElevationRequired == nil {
		t.Fatal("ErrElevationRequired must be a non-nil sentinel")
	}
}
