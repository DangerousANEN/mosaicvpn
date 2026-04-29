//go:build windows

package firewall

import (
	"context"
	"fmt"
	"os/exec"
	"syscall"
	"time"
)

func ruleName(tag string, port int) string {
	return fmt.Sprintf("Mosaic ShareLAN %s %d", tag, port)
}

// AllowInbound opens the given TCP port to inbound traffic on all
// Windows Firewall profiles. Idempotent: if a rule with the same
// name already exists it's refreshed (delete-then-add) so a prior
// tag with different port numbers can't drift. Requires admin; the
// daemon already holds SeTcbPrivilege for TUN so this is a no-op
// from the caller's perspective when it fails.
func AllowInbound(tag string, port int) error {
	if port <= 0 {
		return nil
	}
	// Best-effort: delete any previous instance of the rule so
	// switching SOCKS ports between sessions doesn't leave a stale
	// hole open.
	_ = DenyInbound(tag, port)
	name := ruleName(tag, port)
	args := []string{
		"advfirewall", "firewall", "add", "rule",
		"name=" + name,
		"dir=in",
		"action=allow",
		"protocol=TCP",
		"localport=" + fmt.Sprintf("%d", port),
		"profile=any",
		"description=Mosaic VPN ShareLAN inbound for " + tag,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "netsh", args...)
	// Hide the flash of a console window.
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("netsh add rule %q: %w (%s)", name, err, string(out))
	}
	return nil
}

// DenyInbound removes a rule previously added by AllowInbound. Not
// an error when the rule doesn't exist.
func DenyInbound(tag string, port int) error {
	name := ruleName(tag, port)
	args := []string{
		"advfirewall", "firewall", "delete", "rule",
		"name=" + name,
		"protocol=TCP",
		"localport=" + fmt.Sprintf("%d", port),
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "netsh", args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	// Ignore the exit code — "no rules match the specified criteria"
	// is fine.
	_ = cmd.Run()
	return nil
}
