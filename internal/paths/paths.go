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

// DataDir returns the directory holding persistent application data
// (subscriptions, rules, logs). It does not create the directory.
//
//   - Windows: %ProgramData%\Mosaic
//   - macOS:   ~/Library/Application Support/Mosaic
//   - Linux:   $XDG_DATA_HOME/mosaic or ~/.local/share/mosaic
func DataDir() string {
	switch runtime.GOOS {
	case "windows":
		if d := os.Getenv("ProgramData"); d != "" {
			return filepath.Join(d, AppName)
		}
		return filepath.Join(os.Getenv("SystemDrive"), "ProgramData", AppName)
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
