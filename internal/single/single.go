// Package single enforces single-instance semantics for the Mosaic daemon.
//
// Layered approach:
//
//  1. A platform-specific advisory lock on the lockfile (flock on Unix,
//     LockFileEx on Windows) — survives crashes because the OS releases the
//     lock when the process dies.
//  2. The lockfile content also includes the daemon endpoint (host, port,
//     token, pid). Clients read this file to discover where the daemon
//     listens and to authenticate.
//  3. On Windows the daemon additionally creates a named mutex
//     `Global\Mosaic.daemon` (see single_windows.go); on other platforms
//     the flock is sufficient.
//
// If another instance is already running, Acquire returns ErrAlreadyRunning
// along with the previous endpoint info parsed from the lockfile.
package single

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/DangerousANEN/mosaic/internal/proto"
)

// ErrAlreadyRunning is returned when another daemon instance holds the lock.
var ErrAlreadyRunning = errors.New("another mosaic daemon is already running")

// Lock represents an acquired single-instance lock. Release must be called
// when the daemon shuts down.
type Lock struct {
	path string
	file *os.File
	plat platformLock
}

// Acquire takes the single-instance lock at path and writes the supplied
// endpoint info into the lockfile. If another process already holds the
// lock, the existing endpoint info is returned alongside ErrAlreadyRunning.
func Acquire(path string, ep proto.DaemonEndpoint) (*Lock, *proto.DaemonEndpoint, error) {
	if err := os.MkdirAll(dirOf(path), 0o700); err != nil {
		return nil, nil, fmt.Errorf("ensure lock dir: %w", err)
	}

	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, nil, fmt.Errorf("open lockfile: %w", err)
	}

	plat, err := platformAcquire(f)
	if err != nil {
		// best-effort read of existing endpoint
		var existing proto.DaemonEndpoint
		_ = decodeEndpoint(f, &existing)
		_ = f.Close()
		if errors.Is(err, ErrAlreadyRunning) {
			return nil, &existing, ErrAlreadyRunning
		}
		return nil, nil, err
	}

	if err := writeEndpoint(f, ep); err != nil {
		_ = plat.release()
		_ = f.Close()
		return nil, nil, err
	}

	return &Lock{path: path, file: f, plat: plat}, nil, nil
}

// Release frees the lock and removes the lockfile if it still references
// this process.
func (l *Lock) Release() error {
	if l == nil {
		return nil
	}
	var firstErr error
	if l.plat != nil {
		if err := l.plat.release(); err != nil {
			firstErr = err
		}
	}
	if l.file != nil {
		if err := l.file.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	// Try to remove the file. Best-effort.
	_ = os.Remove(l.path)
	return firstErr
}

// ReadEndpoint reads the endpoint info from a lockfile without touching
// the lock. Used by the CLI/MCP/health probes to discover the daemon.
func ReadEndpoint(path string) (proto.DaemonEndpoint, error) {
	var ep proto.DaemonEndpoint
	f, err := os.Open(path)
	if err != nil {
		return ep, err
	}
	defer f.Close()
	err = decodeEndpoint(f, &ep)
	return ep, err
}

func writeEndpoint(f *os.File, ep proto.DaemonEndpoint) error {
	if _, err := f.Seek(0, 0); err != nil {
		return err
	}
	if err := f.Truncate(0); err != nil {
		return err
	}
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	if err := enc.Encode(ep); err != nil {
		return err
	}
	return f.Sync()
}

func decodeEndpoint(f *os.File, ep *proto.DaemonEndpoint) error {
	if _, err := f.Seek(0, 0); err != nil {
		return err
	}
	dec := json.NewDecoder(f)
	return dec.Decode(ep)
}

func dirOf(p string) string {
	for i := len(p) - 1; i >= 0; i-- {
		if p[i] == '/' || p[i] == '\\' {
			return p[:i]
		}
	}
	return "."
}

// platformLock is the per-OS lock implementation; see single_unix.go
// and single_windows.go.
type platformLock interface {
	release() error
}
