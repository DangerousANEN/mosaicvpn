//go:build windows

package state

import (
	"os/exec"
	"testing"
)

// The sing-box process used to flash a visible console window on every
// connect because the command was spawned without SysProcAttr. These tests
// pin the flags that suppress it so the regression cannot come back
// unnoticed.

const createNoWindow = 0x08000000

func TestHideConsoleWindowSetsFlags(t *testing.T) {
	cmd := exec.Command("cmd.exe", "/c", "echo", "hi")

	hideConsoleWindow(cmd)

	if cmd.SysProcAttr == nil {
		t.Fatal("SysProcAttr is nil: the console window would still appear")
	}
	if !cmd.SysProcAttr.HideWindow {
		t.Error("HideWindow is false, want true")
	}
	if got := cmd.SysProcAttr.CreationFlags; got&createNoWindow == 0 {
		t.Errorf("CreationFlags = %#x, want CREATE_NO_WINDOW (%#x) to be set", got, createNoWindow)
	}
}

// A hidden process must still run and still give us its output, otherwise the
// daemon would lose the sing-box logs it writes to Stdout/Stderr.
func TestHiddenProcessStillRunsAndReturnsOutput(t *testing.T) {
	cmd := exec.Command("cmd.exe", "/c", "echo", "mosaic")
	hideConsoleWindow(cmd)

	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("hidden process failed to run: %v", err)
	}
	if len(out) == 0 {
		t.Error("hidden process produced no output, want captured stdout")
	}
}

// Guard against a caller wiping flags that another layer already set.
func TestHideConsoleWindowIsIdempotent(t *testing.T) {
	cmd := exec.Command("cmd.exe", "/c", "echo", "hi")

	hideConsoleWindow(cmd)
	firstHide := cmd.SysProcAttr.HideWindow
	firstFlags := cmd.SysProcAttr.CreationFlags

	hideConsoleWindow(cmd)

	if cmd.SysProcAttr.HideWindow != firstHide {
		t.Errorf("HideWindow changed on second call: got %v, want %v", cmd.SysProcAttr.HideWindow, firstHide)
	}
	if cmd.SysProcAttr.CreationFlags != firstFlags {
		t.Errorf("CreationFlags changed on second call: got %#x, want %#x", cmd.SysProcAttr.CreationFlags, firstFlags)
	}
	if !cmd.SysProcAttr.HideWindow || cmd.SysProcAttr.CreationFlags&createNoWindow == 0 {
		t.Error("flags were reset instead of preserved")
	}
}
