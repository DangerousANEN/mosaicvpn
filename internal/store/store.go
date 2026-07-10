// Package store persists Mosaic configuration to disk and provides
// concurrency-safe accessors.
//
// The on-disk format is a single JSON file that holds the full set of
// subscriptions, the servers they produce, the routing rules, the
// preferences, and the ID of the last-connected server. Writes are
// atomic (write to *.tmp + rename).
package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

// State is the persistent in-memory representation of all Mosaic data.
// It is the single source of truth for everything that survives a daemon
// restart.
type State struct {
	Subscriptions []proto.Subscription `json:"subscriptions"`
	Servers       []proto.Server       `json:"servers"`
	Rules         []proto.Rule         `json:"rules"`
	Prefs         Prefs                `json:"prefs"`
	LastServerID  string               `json:"last_server_id,omitempty"`
	Version       int                  `json:"version"`
}

// Prefs holds user-configurable behaviour of the daemon.
type Prefs struct {
	TunnelMode      string `json:"tunnel_mode"` // "tun" | "proxy"
	SocksAddr       string `json:"socks_addr"`
	HTTPAddr        string `json:"http_addr"`
	MTU             int    `json:"mtu"`
	KillSwitch      bool   `json:"kill_switch"`
	AllowLAN        bool   `json:"allow_lan"`
	BypassProcesses []string `json:"bypass_processes,omitempty"`
	BlockIPv6       bool   `json:"block_ipv6"`
	DNSMode         string `json:"dns_mode"` // "fake-ip" | "real-ip"
	DNSProxied      string `json:"dns_proxied"`
	DNSDirect       string `json:"dns_direct"`
	ShareLAN        bool   `json:"share_lan"`
	ShareAddr       string `json:"share_addr"`
	ShareAllow      []string `json:"share_allow,omitempty"`
	AutoStart       string `json:"auto_start"` // "service" | "user" | "manual"
	AutoConnect     bool   `json:"auto_connect"`
	ShowOnLaunch    bool   `json:"show_on_launch"`
	MCPEnabled      bool   `json:"mcp_enabled"`
	MCPAddr         string `json:"mcp_addr"`
	MCPPermission   string `json:"mcp_permission"` // "read" | "connect" | "full"
	MCPConfirm      bool   `json:"mcp_confirm"`
}

// DefaultPrefs returns the prefs Mosaic ships with on a fresh install.
func DefaultPrefs() Prefs {
	return Prefs{
		TunnelMode:    "tun",
		SocksAddr:     "127.0.0.1:1080",
		HTTPAddr:      "127.0.0.1:1081",
		MTU:           1420,
		KillSwitch:    true,
		AllowLAN:      true,
		BlockIPv6:     false,
		DNSMode:       "fake-ip",
		DNSProxied:    "https://1.1.1.1/dns-query",
		DNSDirect:     "udp://77.88.8.8",
		ShareLAN:      false,
		ShareAddr:     "0.0.0.0:1080",
		AutoStart:     "service",
		AutoConnect:   true,
		ShowOnLaunch:  true,
		MCPEnabled:    true,
		MCPAddr:       "127.0.0.1:8731",
		MCPPermission: "connect",
		MCPConfirm:    true,
	}
}

// Default returns a State with sensible defaults.
func Default() State {
	return State{
		Prefs:   DefaultPrefs(),
		Version: 1,
	}
}

// Store is a thread-safe wrapper around State backed by a JSON file.
type Store struct {
	mu    sync.RWMutex
	state State
	path  string
}

// Open loads the store at path, creating a default state if the file does
// not exist.
func Open(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("ensure dir: %w", err)
	}
	s := &Store{path: path, state: Default()}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		if err := s.persistLocked(); err != nil {
			return nil, err
		}
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, &s.state); err != nil {
		return nil, fmt.Errorf("decode store: %w", err)
	}
	// Backfill defaults for new fields.
	if s.state.Prefs.SocksAddr == "" {
		s.state.Prefs = DefaultPrefs()
	}
	return s, nil
}

// Snapshot returns a deep-ish copy of the current state. Servers and rules
// are copied by value but Raw maps remain shared — callers must not mutate
// them.
func (s *Store) Snapshot() State {
	s.mu.RLock()
	defer s.mu.RUnlock()
	cp := s.state
	cp.Subscriptions = append([]proto.Subscription(nil), s.state.Subscriptions...)
	cp.Servers = append([]proto.Server(nil), s.state.Servers...)
	cp.Rules = append([]proto.Rule(nil), s.state.Rules...)
	return cp
}

// Update applies fn to a copy of the state under write lock and persists
// the result on success.
func (s *Store) Update(fn func(*State) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := fn(&s.state); err != nil {
		return err
	}
	return s.persistLocked()
}

func (s *Store) persistLocked() error {
	tmp := s.path + ".tmp"
	data, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// AddOrUpdateSubscription stores a subscription. If sub.ID is non-empty it
// updates the existing entry with that ID; otherwise a new subscription is
// always appended (duplicate URLs are allowed). Returns the stored sub.
func (s *Store) AddOrUpdateSubscription(sub proto.Subscription) (proto.Subscription, error) {
	var saved proto.Subscription
	err := s.Update(func(st *State) error {
		if sub.ID != "" {
			for i, existing := range st.Subscriptions {
				if existing.ID == sub.ID {
					st.Subscriptions[i] = sub
					saved = sub
					return nil
				}
			}
		}
		// New subscription — always append, even if URL duplicates an
		// existing one.  The user may legitimately add the same feed twice
		// under different names.
		sub.ID = fmt.Sprintf("sub-%d", time.Now().UnixNano())
		st.Subscriptions = append(st.Subscriptions, sub)
		saved = sub
		return nil
	})
	return saved, err
}

// RenameSubscription updates only the display name of a subscription.
func (s *Store) RenameSubscription(subID, name string) (proto.Subscription, error) {
	var saved proto.Subscription
	err := s.Update(func(st *State) error {
		for i, existing := range st.Subscriptions {
			if existing.ID == subID {
				st.Subscriptions[i].Name = name
				saved = st.Subscriptions[i]
				return nil
			}
		}
		return fmt.Errorf("subscription %q not found", subID)
	})
	return saved, err
}

// ReplaceServersFor replaces all stored servers belonging to subID with the
// supplied list. Each server's SubscriptionID is forced to subID.
func (s *Store) ReplaceServersFor(subID string, servers []proto.Server) error {
	return s.Update(func(st *State) error {
		// keep servers from other subscriptions
		filtered := make([]proto.Server, 0, len(st.Servers))
		for _, sv := range st.Servers {
			if sv.SubscriptionID != subID {
				filtered = append(filtered, sv)
			}
		}
		st.Servers = filtered
		for _, sv := range servers {
			sv.SubscriptionID = subID
			st.Servers = append(st.Servers, sv)
		}
		// stable order: subscription, then name
		sort.SliceStable(st.Servers, func(i, j int) bool {
			a, b := st.Servers[i], st.Servers[j]
			if a.SubscriptionID != b.SubscriptionID {
				return a.SubscriptionID < b.SubscriptionID
			}
			return a.Name < b.Name
		})
		// update count on the subscription record
		for i := range st.Subscriptions {
			if st.Subscriptions[i].ID == subID {
				st.Subscriptions[i].ServerCount = countServers(st.Servers, subID)
				st.Subscriptions[i].LastFetched = time.Now().UTC()
				st.Subscriptions[i].LastError = ""
			}
		}
		return nil
	})
}

// MarkSubscriptionError records a fetch error against a subscription
// without changing its server list.
func (s *Store) MarkSubscriptionError(subID, errMsg string) error {
	return s.Update(func(st *State) error {
		for i := range st.Subscriptions {
			if st.Subscriptions[i].ID == subID {
				st.Subscriptions[i].LastError = errMsg
				st.Subscriptions[i].LastFetched = time.Now().UTC()
				return nil
			}
		}
		return fmt.Errorf("subscription %q not found", subID)
	})
}

func countServers(all []proto.Server, subID string) int {
	n := 0
	for _, s := range all {
		if s.SubscriptionID == subID {
			n++
		}
	}
	return n
}

// FindServer locates a server by id.
func (s *Store) FindServer(id string) (proto.Server, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, sv := range s.state.Servers {
		if sv.ID == id {
			return sv, true
		}
	}
	return proto.Server{}, false
}

// RecordServerProbe stores the result of a TCP probe against a server.
// Pass ms<0 to record a failure with the given error message; pass ms>=0
// with errMsg=="" for a success.
func (s *Store) RecordServerProbe(id string, ms int, errMsg string) error {
	return s.Update(func(st *State) error {
		for i := range st.Servers {
			if st.Servers[i].ID == id {
				st.Servers[i].LastTestMS = ms
				st.Servers[i].LastTestError = errMsg
				st.Servers[i].LastTestAt = time.Now().UTC()
				return nil
			}
		}
		return fmt.Errorf("server %q not found", id)
	})
}

// RecordServerGeo updates the geographic metadata of a server. Call
// with city/country/lat/lon resolved by an external GeoIP lookup; an
// empty string or zero value leaves the field unchanged so partial
// updates are safe.
func (s *Store) RecordServerGeo(id, city, country string, lat, lon float64) error {
	return s.Update(func(st *State) error {
		for i := range st.Servers {
			if st.Servers[i].ID != id {
				continue
			}
			if city != "" {
				st.Servers[i].City = city
			}
			if country != "" {
				st.Servers[i].Country = country
			}
			if lat != 0 || lon != 0 {
				st.Servers[i].Lat = lat
				st.Servers[i].Lon = lon
			}
			return nil
		}
		return fmt.Errorf("server %q not found", id)
	})
}

// SetLastServer remembers which server was most recently chosen.
func (s *Store) SetLastServer(id string) error {
	return s.Update(func(st *State) error {
		st.LastServerID = id
		return nil
	})
}

// SetPrefs replaces preferences wholesale.
func (s *Store) SetPrefs(p Prefs) error {
	return s.Update(func(st *State) error {
		st.Prefs = p
		return nil
	})
}

// AddRule appends a new rule.
func (s *Store) AddRule(r proto.Rule) (proto.Rule, error) {
	var saved proto.Rule
	err := s.Update(func(st *State) error {
		if r.ID == "" {
			r.ID = fmt.Sprintf("rule-%d", time.Now().UnixNano())
		}
		if r.Priority == 0 {
			r.Priority = len(st.Rules) + 1
		}
		st.Rules = append(st.Rules, r)
		saved = r
		return nil
	})
	return saved, err
}

// ReplaceRules sets the full rule list (used for drag-reorder operations).
func (s *Store) ReplaceRules(rules []proto.Rule) error {
	return s.Update(func(st *State) error {
		st.Rules = rules
		return nil
	})
}

// DeleteRule removes a rule by id.
func (s *Store) DeleteRule(id string) error {
	return s.Update(func(st *State) error {
		out := make([]proto.Rule, 0, len(st.Rules))
		for _, r := range st.Rules {
			if r.ID != id {
				out = append(out, r)
			}
		}
		st.Rules = out
		return nil
	})
}

// DeleteSubscription removes a subscription and all its servers.
func (s *Store) DeleteSubscription(subID string) error {
	return s.Update(func(st *State) error {
		subs := make([]proto.Subscription, 0, len(st.Subscriptions))
		for _, sub := range st.Subscriptions {
			if sub.ID != subID {
				subs = append(subs, sub)
			}
		}
		st.Subscriptions = subs

		servers := st.Servers[:0]
		for _, sv := range st.Servers {
			if sv.SubscriptionID != subID {
				servers = append(servers, sv)
			}
		}
		st.Servers = servers
		return nil
	})
}
