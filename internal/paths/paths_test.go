package paths_test

import (
	"testing"

	"github.com/DangerousANEN/mosaicvpn/internal/paths"
)

// TestDataDirEnvOverride locks in the contract that MOSAIC_DATA_DIR
// fully overrides the per-OS default, with no AppName suffix appended.
// The Tauri shell mirrors this exactly; if the two diverge, the GUI
// would look for daemon.lock in a different directory than the one
// the daemon writes into.
func TestDataDirEnvOverride(t *testing.T) {
	t.Setenv(paths.DataDirEnv, "/tmp/mosaic-dev")
	if got := paths.DataDir(); got != "/tmp/mosaic-dev" {
		t.Fatalf("DataDir() = %q, want /tmp/mosaic-dev", got)
	}
}

func TestDataDirEnvEmptyFallsBack(t *testing.T) {
	t.Setenv(paths.DataDirEnv, "")
	if got := paths.DataDir(); got == "" {
		t.Fatal("DataDir() returned empty string with empty override")
	}
}
