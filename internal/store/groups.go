package store

import "github.com/pupspochta-cpu/mosaicvpn/internal/proto"

// Default group IDs. Stable across releases: the UI, the connect chain and
// the seeder all address groups by these strings.
const (
	GroupIDPoolAuto  = "pool-auto"
	GroupIDPoolFast  = "pool-fast"
	GroupIDPoolDE    = "pool-de"
	GroupIDPoolNL    = "pool-nl"
	GroupIDEmergency = "emergency"
)

// DefaultGroups returns the groups every install starts with, per
// GROUP_SYSTEM_SPEC section 7.
//
// Nodes are deliberately empty. The pool fills them at runtime from its
// sources; seeding invented endpoints here would put fake servers in front of
// the user that fail the moment they tap connect.
func DefaultGroups() []proto.ServerGroup {
	groups := []proto.ServerGroup{
		{
			ID:          GroupIDPoolAuto,
			Title:       "Автовыбор",
			Source:      proto.GroupSourcePool,
			Strategy:    proto.GroupStrategyWeightedRoundRobin,
			Criterion:   proto.GroupCriterionAuto,
			Nodes:       []proto.NodeRef{},
			Description: "Балансировка по задержке и загрузке узлов",
			Icon:        "auto_awesome",
		},
		{
			ID:          GroupIDPoolFast,
			Title:       "Минимальный пинг",
			Source:      proto.GroupSourcePool,
			Strategy:    proto.GroupStrategyURLTest,
			Criterion:   proto.GroupCriterionMinPing,
			Nodes:       []proto.NodeRef{},
			Description: "Самый быстрый отклик из доступных узлов",
			Icon:        "bolt",
		},
		{
			ID:             GroupIDPoolDE,
			Title:          "Германия",
			Source:         proto.GroupSourcePool,
			Strategy:       proto.GroupStrategyURLTest,
			Criterion:      proto.GroupCriterionLocation,
			CriterionValue: "DE",
			Nodes:          []proto.NodeRef{},
			Description:    "Узлы в Германии",
			Icon:           "flag",
		},
		{
			ID:             GroupIDPoolNL,
			Title:          "Нидерланды",
			Source:         proto.GroupSourcePool,
			Strategy:       proto.GroupStrategyURLTest,
			Criterion:      proto.GroupCriterionLocation,
			CriterionValue: "NL",
			Nodes:          []proto.NodeRef{},
			Description:    "Узлы в Нидерландах",
			Icon:           "flag",
		},
		{
			ID:          GroupIDEmergency,
			Title:       "Аварийный узел",
			Source:      proto.GroupSourceEmergency,
			Strategy:    proto.GroupStrategyDirectNode,
			Nodes:       []proto.NodeRef{},
			Description: "Запасное подключение, когда остальные группы недоступны",
			Icon:        "health_and_safety",
		},
	}

	for i := range groups {
		groups[i].SetDefaults()
	}
	return groups
}

// seedDefaultGroups adds any missing default group, preserving whatever the
// user already has.
//
// It matches on ID rather than replacing the slice wholesale: a user who
// renamed "Германия" or reordered their groups must not have that edit
// reverted every time the daemon restarts. Returns true if anything changed.
func seedDefaultGroups(state *State) bool {
	existing := make(map[string]bool, len(state.Groups))
	for _, g := range state.Groups {
		existing[g.ID] = true
	}

	changed := false
	for _, g := range DefaultGroups() {
		if existing[g.ID] {
			continue
		}
		state.Groups = append(state.Groups, g)
		changed = true
	}

	if state.Groups == nil {
		state.Groups = []proto.ServerGroup{}
	}
	return changed
}

// Groups returns a copy of the stored groups.
func (s *Store) Groups() []proto.ServerGroup {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]proto.ServerGroup, len(s.state.Groups))
	copy(out, s.state.Groups)
	return out
}

// Group looks up a single group by ID.
func (s *Store) Group(id string) (proto.ServerGroup, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for _, g := range s.state.Groups {
		if g.ID == id {
			return g, true
		}
	}
	return proto.ServerGroup{}, false
}

// SaveGroup inserts or updates a group by ID and persists the store.
func (s *Store) SaveGroup(g proto.ServerGroup) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	g.SetDefaults()
	for i := range s.state.Groups {
		if s.state.Groups[i].ID == g.ID {
			s.state.Groups[i] = g
			return s.persistLocked()
		}
	}
	s.state.Groups = append(s.state.Groups, g)
	return s.persistLocked()
}

// DeleteGroup removes a group by ID. Deleting a default group is allowed but
// it will be re-seeded on the next start; that is intentional so a user can
// never end up with nothing to connect to.
func (s *Store) DeleteGroup(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	for i := range s.state.Groups {
		if s.state.Groups[i].ID == id {
			s.state.Groups = append(s.state.Groups[:i], s.state.Groups[i+1:]...)
			return s.persistLocked()
		}
	}
	return nil
}

// SetGroupNodes replaces the node list of a group, used by the pool after a
// refresh.
func (s *Store) SetGroupNodes(id string, nodes []proto.NodeRef) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	for i := range s.state.Groups {
		if s.state.Groups[i].ID == id {
			s.state.Groups[i].Nodes = nodes
			return s.persistLocked()
		}
	}
	return nil
}
