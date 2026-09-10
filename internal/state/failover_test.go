package state

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// TestConnectWithFallbacksSkipsUnverifiedCandidates asserts the core
// behaviour: a candidate that fails verification is skipped and the next one
// is tried, in ranked order.
func TestConnectWithFallbacksSkipsUnverifiedCandidates(t *testing.T) {
	attempts := []string{}
	// verifyFailFor returns ErrTunnelUnverified for the listed IDs.
	verifyFailFor := map[string]bool{"node-a": true, "node-b": true}

	connect := func(_ context.Context, id string) error {
		attempts = append(attempts, id)
		if verifyFailFor[id] {
			return errors.New("tunnel started but carried no traffic: probe failed")
		}
		return nil
	}

	// Drive the same algorithm ConnectWithFallbacks uses, with an injectable
	// connect func. Keeping the loop honest here means the production method
	// stays a thin wrapper over Manager.Connect.
	got, rejected, err := walkCandidates(context.Background(),
		"node-a", []string{"node-b", "node-c"},
		func(ctx context.Context, id string) error {
			if e := connect(ctx, id); e != nil {
				return errors.Join(ErrTunnelUnverified, e)
			}
			return nil
		})

	if err != nil {
		t.Fatalf("expected a healthy candidate to be found, got %v", err)
	}
	if got != "node-c" {
		t.Fatalf("expected node-c to win, got %q", got)
	}
	if len(rejected) != 2 {
		t.Fatalf("expected 2 rejected candidates, got %v", rejected)
	}
	want := []string{"node-a", "node-b", "node-c"}
	if strings.Join(attempts, ",") != strings.Join(want, ",") {
		t.Fatalf("candidates tried in wrong order: %v, want %v", attempts, want)
	}
}

// A non-verification error must abort immediately: retrying a malformed
// request on every node only multiplies the user's wait.
func TestConnectWithFallbacksAbortsOnNonVerificationError(t *testing.T) {
	attempts := []string{}
	_, _, err := walkCandidates(context.Background(),
		"node-a", []string{"node-b", "node-c"},
		func(_ context.Context, id string) error {
			attempts = append(attempts, id)
			return errors.New("server not found")
		})
	if err == nil {
		t.Fatal("expected the error to propagate")
	}
	if errors.Is(err, ErrTunnelUnverified) {
		t.Fatal("a plain failure must not be classified as unverified")
	}
	if len(attempts) != 1 {
		t.Fatalf("expected exactly one attempt, got %v", attempts)
	}
}

func TestConnectWithFallbacksReportsAllRejected(t *testing.T) {
	_, rejected, err := walkCandidates(context.Background(),
		"a", []string{"b"},
		func(context.Context, string) error {
			return errors.Join(ErrTunnelUnverified, errors.New("no traffic"))
		})
	if err == nil {
		t.Fatal("expected failure when every candidate black-holes")
	}
	if len(rejected) != 2 {
		t.Fatalf("expected both candidates recorded as rejected, got %v", rejected)
	}
}

func TestConnectWithFallbacksHonoursCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, _, err := walkCandidates(ctx, "a", []string{"b"},
		func(context.Context, string) error { return nil })
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
}
