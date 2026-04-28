package state

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/DangerousANEN/mosaicvpn/internal/logx"
)

// EnsureWintunDLL copies wintun.dll into dataDir so sing-box (which
// runs with its working directory pinned to dataDir) can LoadLibrary
// the DLL when the TUN inbound starts. The Tauri NSIS installer drops
// wintun.dll under the install root via bundle.resources; this helper
// is the bridge from the install dir to the daemon's runtime dir.
//
// Search order:
//
//  1. dataDir already has a wintun.dll → no-op.
//  2. Same directory as the running mosaicd executable.
//  3. resources/_up_/binaries/wintun.dll (Tauri 2 NSIS resource layout).
//  4. resources/binaries/wintun.dll (alternate Tauri 2 layout).
//
// Returns nil on success or when wintun is genuinely not bundled — the
// caller is expected to surface a clear "TUN unavailable: wintun.dll
// not bundled" error from Connect, not crash. On non-Windows hosts
// the helper is a no-op.
func EnsureWintunDLL(dataDir string) error {
	target := filepath.Join(dataDir, "wintun.dll")
	if fi, err := os.Stat(target); err == nil && !fi.IsDir() && fi.Size() > 0 {
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locate mosaicd executable: %w", err)
	}
	exeDir := filepath.Dir(exe)
	candidates := []string{
		filepath.Join(exeDir, "wintun.dll"),
		filepath.Join(exeDir, "resources", "_up_", "binaries", "wintun.dll"),
		filepath.Join(exeDir, "resources", "binaries", "wintun.dll"),
		filepath.Join(exeDir, "..", "resources", "_up_", "binaries", "wintun.dll"),
		filepath.Join(exeDir, "..", "resources", "binaries", "wintun.dll"),
	}
	for _, src := range candidates {
		if _, err := os.Stat(src); err != nil {
			continue
		}
		if err := copyFile(src, target); err != nil {
			logx.Warn("copy wintun.dll failed", "src", src, "dst", target, "err", err)
			continue
		}
		logx.Info("staged wintun.dll for sing-box TUN", "src", src, "dst", target)
		return nil
	}
	return errors.New("wintun.dll not bundled; reinstall Mosaic to enable TUN mode")
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}
