//go:build !windows

package state

import "os/exec"

// hideConsoleWindow is a no-op outside Windows.
func hideConsoleWindow(cmd *exec.Cmd) {}
