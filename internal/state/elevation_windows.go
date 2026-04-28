//go:build windows

package state

import (
	"syscall"
	"unsafe"
)

// IsElevated reports whether the current process is running with
// administrator privileges by inspecting its primary token via
// GetTokenInformation(TokenElevation). The TUN backend in sing-box
// requires elevation on Windows to install a wintun adapter and
// program the routing table; without it Connect must refuse early
// and surface a useful error instead of letting sing-box crash.
func IsElevated() bool {
	hproc, err := syscall.GetCurrentProcess()
	if err != nil {
		return false
	}
	var token syscall.Token
	if err := syscall.OpenProcessToken(
		hproc,
		syscall.TOKEN_QUERY,
		&token,
	); err != nil {
		return false
	}
	defer token.Close()

	var elevation uint32
	var retLen uint32
	const tokenElevation = 20
	advapi32 := syscall.NewLazyDLL("advapi32.dll")
	getTokenInfo := advapi32.NewProc("GetTokenInformation")
	r1, _, _ := getTokenInfo.Call(
		uintptr(token),
		uintptr(tokenElevation),
		uintptr(unsafe.Pointer(&elevation)),
		uintptr(unsafe.Sizeof(elevation)),
		uintptr(unsafe.Pointer(&retLen)),
	)
	if r1 == 0 {
		return false
	}
	return elevation != 0
}
