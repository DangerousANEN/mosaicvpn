package api

import (
	"context"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

func TestCandidateProbeUnattemptedSamplesRemainUnknown(t *testing.T) {
	for _, tc := range []struct {
		name, target string
		cancel       bool
	}{
		{name: "rejected policy", target: "http://example.com"},
		{name: "cancelled before execution", cancel: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if tc.cancel {
				cancel()
			}
			result := ProbeCandidateIsolated(ctx, "group", proto.Server{ID: "candidate"}, tc.target, 20)
			if result.Samples != 0 || result.Successes != 0 || result.Successful {
				t.Fatalf("unattempted probe must have zero evidence, got %+v", result)
			}
			if tc.cancel && result.ProbeKind != "cancelled" {
				t.Fatalf("cancellation must be identified before setup, got %q", result.ProbeKind)
			}
		})
	}
}
