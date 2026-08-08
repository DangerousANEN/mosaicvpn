//go:build windows

package single

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/sys/windows"
)

// MutexNamePrefix is the prefix for the named mutex used for single-instance
// enforcement on Windows. The Global\ prefix means the mutex is unique
// system-wide rather than per-session.
//
// The full mutex name is derived from the lockfile path (see mutexNameFor) so
// that daemons using different --data-dir values (portable installs, test
// harnesses, side-by-side instances) do not falsely collide with each other.
const MutexNamePrefix = `Global\Mosaic.daemon`

// mutexNameFor derives a stable, system-wide unique mutex name from the
// lockfile path. Instances sharing a lockfile share a mutex; instances with
// distinct lockfiles get distinct mutexes.
//
// The path is normalised (absolute + cleaned + case-folded, since Windows
// paths are case-insensitive) then hashed, because raw paths contain
// backslashes which are namespace separators in kernel object names and are
// also subject to the MAX_PATH-ish limits on object names.
func mutexNameFor(path string) string {
	if path == "" {
		return MutexNamePrefix
	}
	norm := path
	if abs, err := filepath.Abs(norm); err == nil {
		norm = abs
	}
	norm = strings.ToLower(filepath.Clean(norm))
	sum := sha256.Sum256([]byte(norm))
	return MutexNamePrefix + "." + hex.EncodeToString(sum[:8])
}

// windowsLock holds the named mutex that enforces single-instance
// semantics on Windows. We deliberately do NOT also call LockFileEx on
// the lockfile: an exclusive byte-range lock makes the file unreadable
// from other processes (incl. the GUI's daemon_endpoint, the CLI, and
// even Get-Content), and the named mutex alone is sufficient because
// the kernel releases the mutex when the holding process dies.
type windowsLock struct {
	mutex windows.Handle
}

func platformAcquire(f *os.File) (platformLock, error) {
	lockPath := ""
	if f != nil {
		lockPath = f.Name()
	}

	name, err := windows.UTF16PtrFromString(mutexNameFor(lockPath))
	if err != nil {
		return nil, err
	}
	h, createErr := windows.CreateMutex(nil, false, name)
	// CreateMutex returns ERROR_ALREADY_EXISTS as the *err* even when the
	// handle is valid; treat that as evidence another instance is running.
	if errors.Is(createErr, syscall.Errno(windows.ERROR_ALREADY_EXISTS)) {
		if h != 0 {
			windows.CloseHandle(h)
		}
		return nil, ErrAlreadyRunning
	}
	if createErr != nil {
		return nil, createErr
	}

	return &windowsLock{mutex: h}, nil
}

func (l *windowsLock) release() error {
	if l.mutex != 0 {
		windows.CloseHandle(l.mutex)
	}
	return nil
}
