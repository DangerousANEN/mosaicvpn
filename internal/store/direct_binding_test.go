package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

func TestOpenRestoresDirectPathFromOwnManifest(t *testing.T) {
	for _, tc := range []struct {
		name               string
		foreign, ambiguous bool
		want               string
	}{
		{name: "same subscription", want: "/owned"},
		{name: "foreign manifest", foreign: true},
		{name: "ambiguous routes", ambiguous: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			snapshot := Default()
			snapshot.Servers = []proto.Server{{ID: "group-direct", SubscriptionID: "sub-a", IsVirtualGroup: true, Category: "direct", GroupTag: "direct"}}
			m := &proto.SubscriptionManifest{DirectRoutes: []proto.ManifestGroup{{ID: "provider:sub-a:direct", Category: "direct", DirectPath: "/owned"}}}
			if tc.ambiguous {
				m.DirectRoutes = append(m.DirectRoutes, proto.ManifestGroup{ID: "direct", Category: "direct", DirectPath: "/other"})
			}
			key := "sub-a"
			if tc.foreign {
				key = "sub-b"
			}
			snapshot.ProviderManifests = map[string]*proto.SubscriptionManifest{key: m}
			data, err := json.Marshal(snapshot)
			if err != nil {
				t.Fatal(err)
			}
			file := filepath.Join(t.TempDir(), "store.json")
			if err := os.WriteFile(file, data, 0600); err != nil {
				t.Fatal(err)
			}
			st, err := Open(file)
			if err != nil {
				t.Fatal(err)
			}
			got, _ := st.Snapshot().Servers[0].Raw["mosaic_direct_path"].(string)
			if got != tc.want {
				t.Fatalf("path=%q want %q", got, tc.want)
			}
			reopened, err := Open(file)
			if err != nil {
				t.Fatal(err)
			}
			persisted, _ := reopened.Snapshot().Servers[0].Raw["mosaic_direct_path"].(string)
			if persisted != got {
				t.Fatal("repair not persisted")
			}
		})
	}
}

func TestSaveManifestForSubscriptionPreservesDirectRoutesOnDisk(t *testing.T) {
	file := filepath.Join(t.TempDir(), "store.json")
	st, err := Open(file)
	if err != nil {
		t.Fatal(err)
	}
	m := &proto.SubscriptionManifest{
		ProviderName: "MosaicVPN",
		DirectRoutes: []proto.ManifestGroup{{ID: "provider:sub-a:direct", Category: "direct", DirectPath: "/mosaicws"}},
	}
	if err := st.SaveManifestForSubscription("sub-a", m); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(file)
	if err != nil {
		t.Fatal(err)
	}
	got := reopened.ManifestForSubscription("sub-a")
	if got == nil || len(got.DirectRoutes) != 1 || got.DirectRoutes[0].DirectPath != "/mosaicws" {
		t.Fatalf("direct_routes lost on disk: %#v", got)
	}
}
