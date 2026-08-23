//go:build !windows

package elevate

// IsElevated reports elevation outside Windows. Linux/macOS privilege is
// decided by the OS at process start (sudo, setuid core, installed
// capabilities), so a running daemon either already can create the TUN or
// will fail with its own platform error.
func IsElevated() bool { return true }

// Ensure returns ErrElevationRequired when tunnelMode needs rights the
// process does not have. Non-Windows platforms currently always pass.
func Ensure(tunnelMode string) error {
	if Required(tunnelMode) && !IsElevated() {
		return ErrElevationRequired
	}
	return nil
}
