package subs

import (
	"testing"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

// КОНТРОЛЬНЫЙ ПРИМЕР:
// Узел A: latency=40, weight=10, load=0.90 -> 40/(10*0.1) = 40.0
// Узел B: latency=80, weight=10, load=0.20 -> 80/(10*0.8) = 10.0 <- ДОЛЖЕН БЫТЬ ВЫБРАН
// Узел C: latency=60, weight=5,  load=0.50 -> 60/(5*0.5) = 24.0
func TestWeightedRoundRobin_LoadBalancingBenchmark(t *testing.T) {
	engine := NewPoolEngine()

	servers := []proto.Server{
		{ID: "node-A", Name: "Node A"},
		{ID: "node-B", Name: "Node B"},
		{ID: "node-C", Name: "Node C"},
	}

	engine.SetHealth(HealthStatus{NodeID: "node-A", Alive: true, LatencyMS: 40, Load: 0.90, LastCheck: time.Now()})
	engine.SetHealth(HealthStatus{NodeID: "node-B", Alive: true, LatencyMS: 80, Load: 0.20, LastCheck: time.Now()})
	engine.SetHealth(HealthStatus{NodeID: "node-C", Alive: true, LatencyMS: 60, Load: 0.50, LastCheck: time.Now()})

	group := proto.ManifestGroup{
		ID:   "wrr-group",
		Type: string(proto.GroupStrategyWeightedRoundRobin),
		Nodes: []proto.ManifestNode{
			{ID: "node-A", Weight: 10},
			{ID: "node-B", Weight: 10},
			{ID: "node-C", Weight: 5},
		},
	}

	selected, err := engine.SelectNode(group, servers)
	if err != nil {
		t.Fatalf("SelectNode failed: %v", err)
	}

	if selected.ID != "node-B" {
		t.Errorf("expected node-B (score 10.0), got %s", selected.ID)
	}
}

// Узел с load=0.96 не выбран ни разу за 100 итераций
func TestWeightedRoundRobin_ExcludesHighLoadNode(t *testing.T) {
	engine := NewPoolEngine()

	servers := []proto.Server{
		{ID: "node-overloaded", Name: "Overloaded Node"},
		{ID: "node-normal", Name: "Normal Node"},
	}

	engine.SetHealth(HealthStatus{NodeID: "node-overloaded", Alive: true, LatencyMS: 20, Load: 0.96, LastCheck: time.Now()})
	engine.SetHealth(HealthStatus{NodeID: "node-normal", Alive: true, LatencyMS: 50, Load: 0.50, LastCheck: time.Now()})

	group := proto.ManifestGroup{
		ID:   "wrr-group",
		Type: string(proto.GroupStrategyWeightedRoundRobin),
		Nodes: []proto.ManifestNode{
			{ID: "node-overloaded", Weight: 10},
			{ID: "node-normal", Weight: 10},
		},
	}

	for i := 0; i < 100; i++ {
		selected, err := engine.SelectNode(group, servers)
		if err != nil {
			t.Fatalf("SelectNode failed on iteration %d: %v", i, err)
		}
		if selected.ID == "node-overloaded" {
			t.Fatalf("node-overloaded (load 0.96) was selected on iteration %d", i)
		}
	}
}

// Мёртвый узел (Alive=false) не выбирается никогда
func TestWeightedRoundRobin_ExcludesDeadNode(t *testing.T) {
	engine := NewPoolEngine()

	servers := []proto.Server{
		{ID: "node-dead", Name: "Dead Node"},
		{ID: "node-alive", Name: "Alive Node"},
	}

	engine.SetHealth(HealthStatus{NodeID: "node-dead", Alive: false, LatencyMS: 10, Load: 0.10, LastCheck: time.Now()})
	engine.SetHealth(HealthStatus{NodeID: "node-alive", Alive: true, LatencyMS: 100, Load: 0.50, LastCheck: time.Now()})

	group := proto.ManifestGroup{
		ID:   "wrr-group",
		Type: string(proto.GroupStrategyWeightedRoundRobin),
		Nodes: []proto.ManifestNode{
			{ID: "node-dead", Weight: 10},
			{ID: "node-alive", Weight: 10},
		},
	}

	for i := 0; i < 50; i++ {
		selected, err := engine.SelectNode(group, servers)
		if err != nil {
			t.Fatalf("SelectNode failed on iteration %d: %v", i, err)
		}
		if selected.ID == "node-dead" {
			t.Fatalf("node-dead (Alive=false) was selected on iteration %d", i)
		}
	}
}

// При всех перегруженных узлах возвращается наименее загруженный, а не ошибка
func TestWeightedRoundRobin_GracefulDegradationAllOverloaded(t *testing.T) {
	engine := NewPoolEngine()

	servers := []proto.Server{
		{ID: "node-heavy", Name: "Heavy Load Node"},
		{ID: "node-less-heavy", Name: "Less Heavy Load Node"},
	}

	engine.SetHealth(HealthStatus{NodeID: "node-heavy", Alive: true, LatencyMS: 30, Load: 0.98, LastCheck: time.Now()})
	engine.SetHealth(HealthStatus{NodeID: "node-less-heavy", Alive: true, LatencyMS: 30, Load: 0.95, LastCheck: time.Now()})

	group := proto.ManifestGroup{
		ID:   "wrr-group",
		Type: string(proto.GroupStrategyWeightedRoundRobin),
		Nodes: []proto.ManifestNode{
			{ID: "node-heavy", Weight: 10},
			{ID: "node-less-heavy", Weight: 10},
		},
	}

	selected, err := engine.SelectNode(group, servers)
	if err != nil {
		t.Fatalf("SelectNode failed: %v", err)
	}

	if selected.ID != "node-less-heavy" {
		t.Errorf("expected node-less-heavy (load 0.95), got %s (load %f)", selected.ID, engine.GetHealthStatus(selected.ID).Load)
	}
}
