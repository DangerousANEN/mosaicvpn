package api

import (
	"testing"
	"time"
)

func TestParseSubscriptionUserinfo(t *testing.T) {
	cases := []struct {
		name   string
		header string
		up     uint64
		down   uint64
		total  uint64
		expTS  int64 // 0 = zero time expected
	}{
		{
			name:   "empty",
			header: "",
		},
		{
			name:   "v2board full",
			header: "upload=123; download=456; total=1000; expire=1767225600",
			up:     123,
			down:   456,
			total:  1000,
			expTS:  1767225600,
		},
		{
			name:   "marzban no upload",
			header: "download=42949672960; total=107374182400",
			down:   42949672960,
			total:  107374182400,
		},
		{
			name:   "whitespace and case",
			header: "  Upload = 1 ;  Download=2; TOTAL=3 ; expire=0",
			up:     1,
			down:   2,
			total:  3,
			expTS:  0, // expire=0 → zero time
		},
		{
			name:   "garbage values skipped",
			header: "upload=abc; download=100; foo=bar",
			down:   100,
		},
		{
			name:   "unknown keys ignored",
			header: "x=1; upload=50",
			up:     50,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			up, down, total, exp := parseSubscriptionUserinfo(tc.header)
			if up != tc.up || down != tc.down || total != tc.total {
				t.Fatalf("%s: got up=%d down=%d total=%d; want %d/%d/%d",
					tc.name, up, down, total, tc.up, tc.down, tc.total)
			}
			var want time.Time
			if tc.expTS > 0 {
				want = time.Unix(tc.expTS, 0).UTC()
			}
			if !exp.Equal(want) {
				t.Fatalf("%s: expires %v, want %v", tc.name, exp, want)
			}
		})
	}
}
