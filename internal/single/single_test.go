package single_test

import (
	"errors"
	"path/filepath"
	"testing"

	"github.com/DangerousANEN/mosaic/internal/proto"
	"github.com/DangerousANEN/mosaic/internal/single"
)

func TestAcquireAndRelease(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "daemon.lock")

	ep := proto.DaemonEndpoint{Host: "127.0.0.1", Port: 12345, Token: "tok", PID: 1}

	lock, prev, err := single.Acquire(path, ep)
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	if prev != nil {
		t.Fatalf("expected no previous endpoint, got %+v", prev)
	}

	got, err := single.ReadEndpoint(path)
	if err != nil {
		t.Fatalf("read endpoint: %v", err)
	}
	if got.Port != ep.Port || got.Token != ep.Token {
		t.Fatalf("endpoint mismatch: %+v vs %+v", got, ep)
	}

	if err := lock.Release(); err != nil {
		t.Fatalf("release: %v", err)
	}
}

func TestAcquireDoubleFails(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "daemon.lock")

	ep1 := proto.DaemonEndpoint{Host: "127.0.0.1", Port: 1, Token: "a", PID: 1}
	ep2 := proto.DaemonEndpoint{Host: "127.0.0.1", Port: 2, Token: "b", PID: 2}

	first, _, err := single.Acquire(path, ep1)
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	t.Cleanup(func() { _ = first.Release() })

	_, prev, err := single.Acquire(path, ep2)
	if !errors.Is(err, single.ErrAlreadyRunning) {
		t.Fatalf("expected ErrAlreadyRunning, got %v", err)
	}
	if prev == nil {
		t.Fatal("expected previous endpoint info on conflict")
	}
	if prev.Token != "a" {
		t.Fatalf("expected token 'a' from existing lock, got %q", prev.Token)
	}
}

func TestReleaseAllowsReacquire(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "daemon.lock")

	ep := proto.DaemonEndpoint{Host: "127.0.0.1", Port: 1, Token: "a", PID: 1}

	first, _, err := single.Acquire(path, ep)
	if err != nil {
		t.Fatalf("first: %v", err)
	}
	if err := first.Release(); err != nil {
		t.Fatalf("release: %v", err)
	}

	second, prev, err := single.Acquire(path, ep)
	if err != nil {
		t.Fatalf("re-acquire after release: %v", err)
	}
	if prev != nil {
		t.Fatalf("did not expect previous endpoint after clean release: %+v", prev)
	}
	t.Cleanup(func() { _ = second.Release() })
}
