// Package elevate answers one question for the VPN runtime: may this process
// create a TUN adapter right now? On Windows a TUN adapter requires an
// elevated (administrator) token; without it sing-box fails deep inside the
// wintun driver with an opaque error long after the UI already reported
// "connecting". Detecting the missing privilege before start turns that into
// a deterministic, actionable response — mirroring Throne/Nekoray, which
// checks IsUserAnAdmin() before enabling its VPN mode.
package elevate

import "errors"

// ErrElevationRequired is returned when a tunnel mode that needs administrator
// rights is requested from a non-elevated process. The API layer maps it to
// the machine-readable code `elevation_required` so clients can offer a
// UAC self-restart instead of surfacing a generic runtime failure.
var ErrElevationRequired = errors.New("elevation required: TUN mode needs an administrator token")

// Required reports whether the requested tunnel mode cannot run in the
// current process. Only `tun` needs elevation: proxy mode binds loopback
// listeners that any user may create.
func Required(tunnelMode string) bool {
	return tunnelMode == "tun"
}
