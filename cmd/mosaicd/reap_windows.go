//go:build windows

package main

import (
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/DangerousANEN/mosaicvpn/internal/logx"
)

// reapStaleSingBox finds and force-kills any sing-box.exe processes
// whose command line points at our data directory, leftover from a
// previous crashed UI/daemon. The match is by config-file path
// (mosaicd starts sing-box with `-c <dataDir>/singbox-current.json`),
// so it's narrow enough not to touch unrelated sing-box installs the
// user might run.
//
// We rely on `wmic process` for the listing because it's available on
// every supported Windows SKU (Server 2019+ / Win 10) without any
// extra deps; the alternatives (Toolhelp32Snapshot, NtQueryInformation)
// would pull in more cgo/syscall surface than this is worth for a
// best-effort cleanup.
func reapStaleSingBox(dataDir string) {
	abs, err := filepath.Abs(dataDir)
	if err != nil {
		return
	}
	cfgMarker := strings.ToLower(filepath.Join(abs, "singbox-current.json"))
	dirMarker := strings.ToLower(abs)

	cmd := exec.Command("wmic", "process", "where", "name='sing-box.exe'", "get", "ProcessId,CommandLine", "/format:csv")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	out, err := cmd.Output()
	if err != nil {
		// wmic is deprecated on Win11 24H2+ — fall back silently.
		// The Job Object on the UI side keeps this from mattering.
		logx.Debug("reapStaleSingBox: wmic unavailable", "err", err)
		return
	}

	var killed []int
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// CSV columns: Node, CommandLine, ProcessId
		parts := strings.Split(line, ",")
		if len(parts) < 3 {
			continue
		}
		cmdline := strings.ToLower(strings.Join(parts[1:len(parts)-1], ","))
		pidStr := strings.TrimSpace(parts[len(parts)-1])
		if !strings.Contains(cmdline, cfgMarker) && !strings.Contains(cmdline, dirMarker) {
			continue
		}
		pid, err := strconv.Atoi(pidStr)
		if err != nil || pid <= 0 {
			continue
		}
		// taskkill /T /F kills the process and any child it spawned.
		k := exec.Command("taskkill", "/PID", strconv.Itoa(pid), "/T", "/F")
		k.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
		if err := k.Run(); err != nil {
			logx.Warn("reapStaleSingBox: taskkill failed", "pid", pid, "err", err)
			continue
		}
		killed = append(killed, pid)
	}
	if len(killed) > 0 {
		logx.Info("reapStaleSingBox: killed stale sing-box processes from prior session", "pids", killed)
	}
}
