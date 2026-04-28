//go:build !windows

package state

import "os"

// IsElevated reports whether the current process is running with
// elevated privileges. On Unix the bar is "running as root", which is
// what TUN-style network capture requires there. On Windows see
// elevation_windows.go.
func IsElevated() bool {
	return os.Geteuid() == 0
}
