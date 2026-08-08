package proto

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestNodeRef_JSONRoundTrip(t *testing.T) {
	node := NodeRef{
		ServerID:  "srv-1",
		Weight:    50,
		Load:      0.45,
		LatencyMs: 85,
		Alive:     true,
		LastSeen:  1700000000,
		Country:   "DE",
		City:      "Frankfurt",
	}

	data, err := json.Marshal(node)
	if err != nil {
		t.Fatalf("Marshal failed: %v", err)
	}

	var decoded NodeRef
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("Unmarshal failed: %v", err)
	}

	if decoded != node {
		t.Fatalf("JSON round-trip mismatch:\nExpected: %+v\nGot:      %+v", node, decoded)
	}
}

func TestServerGroup_JSONRoundTrip(t *testing.T) {
	group := ServerGroup{
		ID:             "pool-de",
		Title:          "Германия",
		Source:         GroupSourcePool,
		Strategy:       GroupStrategyURLTest,
		Criterion:      GroupCriterionLocation,
		CriterionValue: "DE",
		Nodes: []NodeRef{
			{
				ServerID:  "node-1",
				Weight:    10,
				Load:      0.2,
				LatencyMs: 40,
				Alive:     true,
				LastSeen:  1700000000,
				Country:   "DE",
				City:      "Berlin",
			},
			{
				ServerID:  "node-2",
				Weight:    20,
				Load:      0.8,
				LatencyMs: 60,
				Alive:     true,
				LastSeen:  1700000001,
				Country:   "DE",
				City:      "Munich",
			},
		},
		RequiredTier:  TierPro,
		PingInterval:  45,
		MaxRetries:    5,
		FailoverDelay: 3,
		Badge:         "Быстрый",
		Description:   "Группа немецких серверов",
		Icon:          "flag_de",
	}

	data, err := json.Marshal(group)
	if err != nil {
		t.Fatalf("Marshal failed: %v", err)
	}

	var decoded ServerGroup
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("Unmarshal failed: %v", err)
	}

	if !reflect.DeepEqual(decoded, group) {
		t.Fatalf("JSON round-trip mismatch:\nExpected: %+v\nGot:      %+v", group, decoded)
	}
}

func TestServerGroup_DefaultValues(t *testing.T) {
	g := ServerGroup{
		ID:    "test-group",
		Title: "Test",
	}
	g.SetDefaults()

	if g.PingInterval != 30 {
		t.Errorf("Expected PingInterval=30, got %d", g.PingInterval)
	}
	if g.MaxRetries != 3 {
		t.Errorf("Expected MaxRetries=3, got %d", g.MaxRetries)
	}
	if g.FailoverDelay != 2 {
		t.Errorf("Expected FailoverDelay=2, got %d", g.FailoverDelay)
	}

	// Test NewServerGroup constructor
	newG := NewServerGroup()
	if newG.PingInterval != 30 || newG.MaxRetries != 3 || newG.FailoverDelay != 2 {
		t.Errorf("NewServerGroup defaults incorrect: %+v", newG)
	}

	// Test preserving existing non-zero values
	customG := ServerGroup{
		PingInterval:  15,
		MaxRetries:    1,
		FailoverDelay: 5,
	}
	customG.SetDefaults()
	if customG.PingInterval != 15 || customG.MaxRetries != 1 || customG.FailoverDelay != 5 {
		t.Errorf("SetDefaults overwritten custom non-zero values: %+v", customG)
	}
}

func TestManifestGroup_ToServerGroup(t *testing.T) {
	mg := ManifestGroup{
		ID:            "mg-1",
		Title:         "Manifest Group 1",
		Type:          "urltest",
		Nodes: []ManifestNode{
			{ID: "node-a", Weight: 25, Priority: 1},
			{ID: "node-b", Weight: 0, Priority: 2}, // Weight 0 should default to 10
		},
		UserTier:      TierVIP,
		Badge:         "VIP Group",
		Category:      "smart",
		Icon:          "shield",
		Description:   "Description for manifest group",
		PingInterval:  0, // should get default 30
		MaxRetries:    0, // should get default 3
		FailoverDelay: 0, // should get default 2
	}

	sg := mg.ToServerGroup()

	if sg.ID != mg.ID {
		t.Errorf("Expected ID %s, got %s", mg.ID, sg.ID)
	}
	if sg.Title != mg.Title {
		t.Errorf("Expected Title %s, got %s", mg.Title, sg.Title)
	}
	if sg.Source != GroupSourceUser {
		t.Errorf("Expected Source %s, got %s", GroupSourceUser, sg.Source)
	}
	if sg.Strategy != GroupStrategyURLTest {
		t.Errorf("Expected Strategy %s, got %s", GroupStrategyURLTest, sg.Strategy)
	}
	if sg.Criterion != GroupCriterionAuto {
		t.Errorf("Expected Criterion %s, got %s", GroupCriterionAuto, sg.Criterion)
	}
	if sg.RequiredTier != TierVIP {
		t.Errorf("Expected RequiredTier %s, got %s", TierVIP, sg.RequiredTier)
	}
	if sg.Badge != mg.Badge {
		t.Errorf("Expected Badge %s, got %s", mg.Badge, sg.Badge)
	}
	if sg.Description != mg.Description {
		t.Errorf("Expected Description %s, got %s", mg.Description, sg.Description)
	}
	if sg.Icon != mg.Icon {
		t.Errorf("Expected Icon %s, got %s", mg.Icon, sg.Icon)
	}
	if sg.PingInterval != 30 {
		t.Errorf("Expected default PingInterval 30, got %d", sg.PingInterval)
	}
	if sg.MaxRetries != 3 {
		t.Errorf("Expected default MaxRetries 3, got %d", sg.MaxRetries)
	}
	if sg.FailoverDelay != 2 {
		t.Errorf("Expected default FailoverDelay 2, got %d", sg.FailoverDelay)
	}

	if len(sg.Nodes) != 2 {
		t.Fatalf("Expected 2 nodes, got %d", len(sg.Nodes))
	}
	if sg.Nodes[0].ServerID != "node-a" || sg.Nodes[0].Weight != 25 || !sg.Nodes[0].Alive {
		t.Errorf("Node 0 converted incorrectly: %+v", sg.Nodes[0])
	}
	if sg.Nodes[1].ServerID != "node-b" || sg.Nodes[1].Weight != 10 || !sg.Nodes[1].Alive {
		t.Errorf("Node 1 converted incorrectly: %+v", sg.Nodes[1])
	}
}
