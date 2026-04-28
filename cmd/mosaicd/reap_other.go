//go:build !windows

package main

// reapStaleSingBox is a no-op on non-Windows platforms. mosaicd on
// Linux/macOS uses POSIX signals for shutdown, which does deliver
// to children; orphaned sing-box processes there are handled by
// the OS via SIGHUP from the parent process group.
func reapStaleSingBox(_ string) {}
