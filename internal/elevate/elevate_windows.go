//go:build windows

package elevate

import "golang.org/x/sys/windows"

// IsElevated reports whether the current process token carries the
// administrator elevation. It caches nothing: the token of a live process
// never changes, but tests may run each check in a fresh process.
func IsElevated() bool {
	return windows.GetCurrentProcessToken().IsElevated()
}

// Ensure returns ErrElevationRequired when tunnelMode needs rights the
// process does not have.
func Ensure(tunnelMode string) error {
	if Required(tunnelMode) && !IsElevated() {
		return ErrElevationRequired
	}
	return nil
}
