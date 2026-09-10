package state

import (
	"path/filepath"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/netmemory"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

// Route memory is only useful if it survives a restart: a ledger that lives in
// RAM relearns every block from scratch on the next launch, which is exactly
// when the user least wants to sit through a failing route.
func TestRouteMemorySurvivesDaemonRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "store.json")

	// --- session 1: learn that "broken" black-holes and "working" does not ---
	st1, err := store.Open(path)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	mgr1 := &Manager{store: st1}
	mgr1.EnableRouteMemory(netmemory.New(), func() string { return "net-home" })

	mgr1.rememberOutcome("broken", false, 0)
	mgr1.rememberOutcome("broken", false, 0)
	mgr1.rememberOutcome("working", true, 75)

	// --- session 2: a fresh daemon reloads what was learned ---
	st2, err := store.Open(path)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	saved := st2.RouteMemory()
	if saved == nil {
		t.Fatal("route memory was not persisted to disk")
	}

	mem2 := netmemory.New()
	mem2.Load(saved)
	mgr2 := &Manager{store: st2}
	mgr2.EnableRouteMemory(mem2, func() string { return "net-home" })

	// The resolver still ranks "broken" first (best latency on paper); memory
	// must override that from the very first attempt after restart.
	primary, fallbacks := mgr2.applyRouteMemory("broken", []string{"working"})
	if primary != "working" {
		t.Fatalf("restored memory failed to promote the proven route, got %q", primary)
	}
	if len(fallbacks) != 1 || fallbacks[0] != "broken" {
		t.Fatalf("demoted route must remain a fallback, got %v", fallbacks)
	}
}

// A store written by an older build has no route_memory key at all; loading it
// must not panic or wipe unrelated state.
func TestStoreWithoutRouteMemoryLoadsCleanly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "store.json")
	st, err := store.Open(path)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	if got := st.RouteMemory(); got != nil {
		t.Fatalf("a fresh store must report no route memory, got %v", got)
	}

	mem := netmemory.New()
	mem.Load(st.RouteMemory()) // nil input must be safe
	mgr := &Manager{store: st}
	mgr.EnableRouteMemory(mem, func() string { return "net" })

	primary, fallbacks := mgr.applyRouteMemory("a", []string{"b"})
	if primary != "a" || len(fallbacks) != 1 {
		t.Fatalf("empty memory must not reorder, got %q %v", primary, fallbacks)
	}
}
