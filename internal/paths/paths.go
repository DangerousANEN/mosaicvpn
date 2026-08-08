// Package paths returns platform-appropriate file system locations for
// Mosaic data. It exists in one place so the rest of the code never has
// to branch on runtime.GOOS.
package paths

import (
	"os"
	"path/filepath"
	"runtime"
)

// AppName is the directory used for Mosaic data on disk.
const AppName = "Mosaic"

// DataDirEnv is the env-var that overrides every other data-dir lookup.
// It is the single source of truth shared between the daemon and the
// Tauri shell so the GUI can locate the lockfile written by the daemon
// regardless of the host's per-user defaults.
const DataDirEnv = "MOSAIC_DATA_DIR"

// DataDir returns the directory holding persistent application data
// (subscriptions, rules, logs). It does not create the directory.
//
//   - $MOSAIC_DATA_DIR if set (used as-is, no AppName suffix appended)
//   - Windows: %LOCALAPPDATA%\Mosaic  (per-user, always writable)
//   - macOS:   ~/Library/Application Support/Mosaic
//   - Linux:   $XDG_DATA_HOME/mosaic or ~/.local/share/mosaic
//
// On Windows we prefer %LOCALAPPDATA% over %ProgramData% because
// %ProgramData% requires elevation for writes — a non-elevated daemon
// cannot persist store.json there.  %LOCALAPPDATA% is always writable
// by the current user.
func DataDir() string {
	if d := os.Getenv(DataDirEnv); d != "" {
		return d
	}
	switch runtime.GOOS {
	case "windows":
		if la := os.Getenv("LOCALAPPDATA"); la != "" {
			return filepath.Join(la, AppName)
		}
		home, _ := os.UserHomeDir()
		return filepath.Join(home, "AppData", "Local", AppName)
	case "darwin":
		home, _ := os.UserHomeDir()
		return filepath.Join(home, "Library", "Application Support", AppName)
	default:
		if d := os.Getenv("XDG_DATA_HOME"); d != "" {
			return filepath.Join(d, "mosaic")
		}
		home, _ := os.UserHomeDir()
		return filepath.Join(home, ".local", "share", "mosaic")
	}
}

// LockFile returns the path to the daemon's PID/endpoint lockfile inside dir.
func LockFile(dir string) string { return filepath.Join(dir, "daemon.lock") }

// LogFile returns the path to the daemon's main log file inside dir.
func LogFile(dir string) string { return filepath.Join(dir, "daemon.log") }

// StoreFile returns the path to the persistent JSON state store inside dir.
func StoreFile(dir string) string { return filepath.Join(dir, "store.json") }

// EnsureDir creates dir with mode 0o700 if it does not already exist.
func EnsureDir(dir string) error { return os.MkdirAll(dir, 0o700) }

// EnsureDataDir creates the data directory and verifies it is writable.
// On Windows the primary path is already %LOCALAPPDATA%\Mosaic (per-user,
// always writable).  If for some reason that fails, it falls back to a
// temp directory.
func EnsureDataDir() (string, error) {
	dir := DataDir()
	if err := os.MkdirAll(dir, 0o700); err == nil {
		probe := filepath.Join(dir, ".writeprobe")
		if err := os.WriteFile(probe, []byte("ok"), 0o600); err == nil {
			_ = os.Remove(probe)
			return dir, nil
		}
	}
	// Last resort: temp directory.
	dir = filepath.Join(os.TempDir(), "mosaic")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return dir, err
	}
	return dir, nil
}
