//go:build windows

package single

import (
	"errors"
	"os"
	"syscall"

	"golang.org/x/sys/windows"
)

// MutexName is the global named-mutex used for single-instance enforcement
// on Windows. The Global\ prefix means it is unique system-wide rather
// than per-session.
const MutexName = `Global\Mosaic.daemon`

// windowsLock holds the named mutex that enforces single-instance
// semantics on Windows. We deliberately do NOT also call LockFileEx on
// the lockfile: an exclusive byte-range lock makes the file unreadable
// from other processes (incl. the GUI's daemon_endpoint, the CLI, and
// even Get-Content), and the named mutex alone is sufficient because
// the kernel releases the mutex when the holding process dies.
type windowsLock struct {
	mutex windows.Handle
}

func platformAcquire(_ *os.File) (platformLock, error) {
	name, err := windows.UTF16PtrFromString(MutexName)
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
