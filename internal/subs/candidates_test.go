package subs

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

func TestDeriveCandidatesURL(t *testing.T) {
	cases := []struct {
		sub, want string
	}{
		{"https://sub.zxc1x1.ru/QPbb-ZB5m4s-FFPL", "https://sub.zxc1x1.ru/api/client-candidates/QPbb-ZB5m4s-FFPL"},
		{"https://sub.zxc1x1.ru/reftcT_frzSCwhav", "https://sub.zxc1x1.ru/api/client-candidates/reftcT_frzSCwhav"},
		{"https://example.com/sub", ""},  // too short
		{"not a url %%%", ""},            // unparseable
	}
	for _, c := range cases {
		got := deriveCandidatesURL(c.sub)
		if got != c.want {
			t.Errorf("deriveCandidatesURL(%q) = %q; want %q", c.sub, got, c.want)
		}
	}
}

func TestFetchCandidateFeed(t *testing.T) {
	feed := CandidateFeed{
		Outbounds: []map[string]any{
			{
				"type":                   "vless",
				"tag":                    "cand-1",
				"server":                 "1.2.3.4",
				"server_port":            443,
				"uuid":                   "u-1",
				"mosaic_group_ids": []any{"min_latency", "germany"},
				"mosaic_country":         "DE",
				"mosaic_stable":          true,
			},
			{"type": "selector", "tag": "ignore-me"},
		},
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/api/client-candidates/") {
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode(feed)
	}))
	defer srv.Close()

	subURL := srv.URL + "/QPbb-ZB5m4s-FFPL"
	got, err := FetchCandidateFeed(context.Background(), subURL)
	if err != nil || got == nil {
		t.Fatalf("FetchCandidateFeed: feed=%v err=%v", got, err)
	}
	if len(got.Outbounds) != 2 {
		t.Fatalf("outbounds = %d; want 2", len(got.Outbounds))
	}

	servers := CandidatesToServers(got)
	if len(servers) != 1 {
		t.Fatalf("CandidatesToServers produced %d servers; want 1 (selector skipped)", len(servers))
	}
	s := servers[0]
	if s.Category != "candidate" {
		t.Errorf("Category = %q; want candidate", s.Category)
	}
	if s.SubscriptionID != CandidateSubID {
		t.Errorf("SubscriptionID = %q; want %q", s.SubscriptionID, CandidateSubID)
	}

	groups := CandidateGroups(s.Raw)
	hasAll, hasDE := false, false
	for _, g := range groups {
		switch g {
		case "rg-all":
			hasAll = true
		case "auto-de":
			hasDE = true
		}
	}
	if !hasAll || !hasDE {
		t.Errorf("groups = %v; want rg-all and auto-de", groups)
	}
}

func TestFetchCandidateFeedMissing(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	defer srv.Close()
	got, err := FetchCandidateFeed(context.Background(), srv.URL+"/short")
	if got != nil || err != nil {
		t.Errorf("expected silent nil,nil for missing feed; got %v,%v", got, err)
	}
}

func TestMatchGroupFilterCandidateMembership(t *testing.T) {
	cand := proto.Server{
		ID:             "c-1",
		Category:       "candidate",
		Name:           "mosaic-candidate-ab12cd34ef56",
		Raw:            map[string]any{"mosaic_group_ids": []any{"min_latency", "germany"}, "mosaic_country": "DE"},
		Protocol:       proto.ProtoVLESS,
	}

	tests := []struct {
		groupID string
		want    bool
	}{
		{"rg-all", true},
		{"auto-de", true},
		{"germany", true},
		{"min-latency", true},
		{"auto-stable", false}, // not flagged stable
		{"auto-nl", false},
	}
	for _, tc := range tests {
		g := proto.ManifestGroup{ID: tc.groupID, Category: "smart"}
		if got := matchGroupFilter(g, cand); got != tc.want {
			t.Errorf("matchGroupFilter(%q) = %v; want %v", tc.groupID, got, tc.want)
		}
	}
}

func TestGroupCountryFromIDAliases(t *testing.T) {
	cases := map[string]string{
		"germany":   "DE",
		"canada":    "CA",
		"netherlands": "NL",
		"usa":       "US",
		"france":    "FR",
		"russia":    "RU",
		"auto-de":   "DE",
		"auto-gb":   "GB",
		"rg-all":    "",
		"stable":    "",
		"max-speed": "",
	}
	for id, want := range cases {
		if got := groupCountryFromID(id); got != want {
			t.Errorf("groupCountryFromID(%q) = %q; want %q", id, got, want)
		}
	}
}

func TestSynthesizeIncludesQualityGroups(t *testing.T) {
	rawServers := []proto.Server{
		{ID: "a", Category: "candidate", Name: "mosaic-candidate-a", Raw: map[string]any{"mosaic_stable": true}},
		{ID: "b", Category: "candidate", Name: "mosaic-candidate-b", Raw: map[string]any{"mosaic_speed_eligible": true}},
		{ID: "c", Name: "Free LTE mobile node"},
	}
	m := SynthesizeManifest("t", rawServers)
	ids := map[string]bool{}
	for _, g := range m.Groups {
		ids[g.ID] = true
	}
	for _, want := range []string{"rg-all", "auto-whitelist", "auto-stable", "auto-speed", "auto-lte"} {
		if !ids[want] {
			t.Errorf("synthesized manifest missing group %q (have %v)", want, ids)
		}
	}
}
