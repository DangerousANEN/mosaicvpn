//go:build windows

package single

import (
	"errors"
	"os"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// MutexName is the global named-mutex used for single-instance enforcement
// on Windows. The Global\ prefix means it is unique system-wide rather
// than per-session.
const MutexName = `Global\Mosaic.daemon`

// windowsLock holds the named mutex AND an OS file lock on the lockfile.
// Either alone would be sufficient; together they're robust to crashes.
type windowsLock struct {
	mutex windows.Handle
	file  *os.File
}

func platformAcquire(f *os.File) (platformLock, error) {
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

	// Lock the lockfile with LockFileEx (exclusive, non-blocking).
	overlapped := windows.Overlapped{}
	if err := windows.LockFileEx(
		windows.Handle(f.Fd()),
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
		0, ^uint32(0), ^uint32(0), &overlapped,
	); err != nil {
		windows.CloseHandle(h)
		// ERROR_LOCK_VIOLATION (0x21) means another process is holding it.
		var errno syscall.Errno
		if errors.As(err, &errno) && uintptr(errno) == 0x21 {
			return nil, ErrAlreadyRunning
		}
		return nil, err
	}

	return &windowsLock{mutex: h, file: f}, nil
}

func (l *windowsLock) release() error {
	overlapped := windows.Overlapped{}
	_ = windows.UnlockFileEx(windows.Handle(l.file.Fd()), 0, ^uint32(0), ^uint32(0), &overlapped)
	if l.mutex != 0 {
		windows.CloseHandle(l.mutex)
	}
	return nil
}

// keep unsafe imported for future expansion (handle inheritance).
var _ = unsafe.Pointer(nil)
