//go:build !windows

package single

import (
	"errors"
	"os"
	"syscall"
)

// unixLock holds an exclusive flock on the lockfile.
type unixLock struct {
	fd int
}

func platformAcquire(f *os.File) (platformLock, error) {
	fd := int(f.Fd())
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, ErrAlreadyRunning
		}
		return nil, err
	}
	return &unixLock{fd: fd}, nil
}

func (l *unixLock) release() error {
	return syscall.Flock(l.fd, syscall.LOCK_UN)
}
