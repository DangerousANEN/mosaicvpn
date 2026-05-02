package state

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/DangerousANEN/mosaicvpn/internal/logx"
)

// EnsureWintunDLL copies wintun.dll into dataDir so sing-box (which
// runs with its working directory pinned to dataDir) can LoadLibrary
// the DLL when the TUN inbound starts. The Tauri NSIS installer drops
// wintun.dll under the install root via bundle.resources; this helper
// is the bridge from the install dir to the daemon's runtime dir.
//
// Search order (verified against the rc21 NSIS installer layout —
// tauri 2 just preserves bundle.resources paths verbatim relative to
// the install root):
//
//  1. dataDir already has a wintun.dll → no-op.
//  2. <install>/binaries/wintun.dll (matches bundle.resources entry).
//  3. <install>/wintun.dll (legacy / sidecar layout).
//  4. <install>/resources/binaries/wintun.dll (older Tauri 1 layout).
//  5. <install>/resources/_up_/binaries/wintun.dll (when src path
//     traversed upward — kept defensively).
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
		filepath.Join(exeDir, "binaries", "wintun.dll"),
		filepath.Join(exeDir, "wintun.dll"),
		filepath.Join(exeDir, "resources", "binaries", "wintun.dll"),
		filepath.Join(exeDir, "resources", "_up_", "binaries", "wintun.dll"),
		filepath.Join(exeDir, "..", "binaries", "wintun.dll"),
		filepath.Join(exeDir, "..", "resources", "binaries", "wintun.dll"),
		filepath.Join(exeDir, "..", "resources", "_up_", "binaries", "wintun.dll"),
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
	return fmt.Errorf(
		"wintun.dll not bundled; reinstall Mosaic to enable TUN mode (looked in: %s)",
		strings.Join(candidates, ", "),
	)
}

// EnsureLibcronetDLL stages libcronet.dll alongside the daemon
// data dir.  Sing-box's `naive` outbound (re-added in 1.13 via
// the bundled Cronet runtime) LoadLibrary's libcronet.dll from
// the working directory at runtime; without it sing-box refuses
// to load any config that references type:"naive" with a
// "missing libcronet" diagnostic.  We always best-effort stage
// it because the user may flip a non-naive server to naive at
// any time and we don't want a surprise startup failure.
//
// Search order matches EnsureWintunDLL — the installer drops
// libcronet.dll under the same `binaries/` path via
// bundle.resources, plus a few historical Tauri layouts as
// belt-and-braces.  Returns nil when the DLL is genuinely not
// bundled (this build doesn't include it) so non-naive users
// don't get spurious connect failures.
func EnsureLibcronetDLL(dataDir string) error {
	target := filepath.Join(dataDir, "libcronet.dll")
	if fi, err := os.Stat(target); err == nil && !fi.IsDir() && fi.Size() > 0 {
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locate mosaicd executable: %w", err)
	}
	exeDir := filepath.Dir(exe)
	candidates := []string{
		filepath.Join(exeDir, "binaries", "libcronet.dll"),
		filepath.Join(exeDir, "libcronet.dll"),
		filepath.Join(exeDir, "resources", "binaries", "libcronet.dll"),
		filepath.Join(exeDir, "resources", "_up_", "binaries", "libcronet.dll"),
		filepath.Join(exeDir, "..", "binaries", "libcronet.dll"),
		filepath.Join(exeDir, "..", "resources", "binaries", "libcronet.dll"),
		filepath.Join(exeDir, "..", "resources", "_up_", "binaries", "libcronet.dll"),
	}
	for _, src := range candidates {
		if _, err := os.Stat(src); err != nil {
			continue
		}
		if err := copyFile(src, target); err != nil {
			logx.Warn("copy libcronet.dll failed", "src", src, "dst", target, "err", err)
			continue
		}
		logx.Info("staged libcronet.dll for sing-box naive", "src", src, "dst", target)
		return nil
	}
	// Soft-fail: not every build bundles libcronet, and only
	// naive servers actually need it. The Connect path will
	// surface a clean "naive requires libcronet.dll" error if
	// the user does try a naive server.
	return nil
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
