package state

import (
	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"testing"
)

func TestDirectGroupExplicitPath(t *testing.T) {
	group := proto.Server{ID: "group-direct", GroupTag: "direct", Category: "direct", IsVirtualGroup: true, Raw: map[string]any{"mosaic_direct_path": "/direct"}}
	for _, tc := range []struct {
		name string
		raw  map[string]any
		want bool
	}{
		{"own route", map[string]any{"path": "/direct"}, true},
		{"other path", map[string]any{"path": "/other"}, false},
		{"pool candidate", map[string]any{"path": "/direct", "mosaic_client_candidate": true}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			candidate := proto.Server{Raw: tc.raw}
			if got := virtualGroupAllowsCandidate(group, candidate, ""); got != tc.want {
				t.Fatalf("Direct membership = %v, want %v", got, tc.want)
			}
		})
	}
}
