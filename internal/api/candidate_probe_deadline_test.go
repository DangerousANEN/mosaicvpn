package api

import (
	"context"
	"testing"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

func TestCandidateProbeQueueHasInternalDeadline(t *testing.T) {
	for i := 0; i < MaxConcurrentCandidateProbes; i++ {
		candidateProbeSem <- struct{}{}
	}
	defer func() {
		for i := 0; i < MaxConcurrentCandidateProbes; i++ {
			<-candidateProbeSem
		}
	}()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan string, 1)
	go func() {
		result := ProbeCandidateIsolated(ctx, "queue-test", proto.Server{ID: "node", Protocol: proto.ProtoVLESS, Address: "example.com", Port: 443}, DefaultCandidateProbeURL, 1)
		done <- result.ProbeKind
	}()
	select {
	case kind := <-done:
		if kind != "concurrency_timeout" {
			t.Fatalf("kind=%q, want concurrency_timeout", kind)
		}
	case <-time.After(17 * time.Second):
		cancel()
		<-done
		t.Fatal("queue wait exceeded internal 15-second budget without a caller deadline")
	}
}
