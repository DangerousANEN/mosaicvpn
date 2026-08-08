//go:build windows

package state

import (
	"os/exec"
	"syscall"
)

// hideConsoleWindow prevents Windows from opening a console window for the
// spawned process. Without this the sing-box process flashes a black console
// on every connect.
func hideConsoleWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: 0x08000000, // CREATE_NO_WINDOW
	}
}
