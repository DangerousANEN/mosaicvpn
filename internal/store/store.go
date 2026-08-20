// Package store persists Mosaic configuration to disk and provides
// concurrency-safe accessors.
//
// The on-disk format is a single JSON file that holds the full set of
// subscriptions, the servers they produce, the routing rules, the
// preferences, and the ID of the last-connected server. Writes are
// atomic (write to *.tmp + rename).
package store

import (
	"crypto/rand"
	"encoding/hex"
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
	Subscriptions   []proto.Subscription `json:"subscriptions"`
	Servers         []proto.Server       `json:"servers"`
	Rules           []proto.Rule         `json:"rules"`
	Prefs           Prefs                `json:"prefs"`
	LastServerID    string               `json:"last_server_id,omitempty"`
	Profiles        []proto.Profile      `json:"profiles"`
	RouteProfiles   []proto.RouteProfile `json:"route_profiles"`
	WARP            proto.WARPConfig     `json:"warp"`
	ActiveProfileID string               `json:"active_profile_id,omitempty"`
	Egresses        []proto.Egress       `json:"egresses,omitempty"`
	AntiDPI         proto.AntiDPIConfig  `json:"anti_dpi,omitempty"`
	// ActiveManifest is retained as a legacy compatibility view. New code must
	// resolve manifests by provider subscription ID through ProviderManifests.
	ActiveManifest    *proto.SubscriptionManifest            `json:"active_manifest,omitempty"`
	ProviderAccounts  []proto.ProviderAccount                `json:"provider_accounts,omitempty"`
	ProviderManifests map[string]*proto.SubscriptionManifest `json:"provider_manifests,omitempty"`
	Version           int                                    `json:"version"`
	// Account is retained for compatibility with pre-v0.3.24 clients. New
	// provider cabinet authorization belongs to one local subscription ID.
	Account         Account            `json:"account,omitempty"`
	CabinetBindings map[string]Account `json:"cabinet_bindings,omitempty"`

	// Billing credentials persisted so the daemon can rebuild the
	// billing.Client across restarts without requiring the user to
	// re-enter them in the UI. Stored as plain strings to keep the
	// store package free of a billing package import.
	RemnawaveURL   string `json:"remnawave_url,omitempty"`
	RemnawaveToken string `json:"remnawave_token,omitempty"`
	CryptoBotToken string `json:"cryptobot_token,omitempty"`
	CryptoBotURL   string `json:"cryptobot_url,omitempty"`

	// YooKassa (ЮKassa) credentials for SBP/card payments.
	YookassaShopID    string `json:"yookassa_shop_id,omitempty"`
	YookassaSecretKey string `json:"yookassa_secret_key,omitempty"`

	// Promo codes and redemption log
	Promos      []PromoEntry      `json:"promos,omitempty"`
	Redemptions []RedemptionEntry `json:"redemptions,omitempty"`

	// Groups are the unified node-selection entities. Seeded on first run so
	// a fresh install has something to connect to without any setup.
	Groups []proto.ServerGroup `json:"groups,omitempty"`

	// LastGroupID is the last group that produced a working connection. Step 2
	// of the connect priority chain prefers it over the generic pool-auto.
	LastGroupID string `json:"last_group_id,omitempty"`

	// LinkCodes are single-use pairing codes issued by the bot so a client
	// can link to an account without the user pasting a raw telegram_id.
	// See account.go.
	LinkCodes []LinkCode `json:"link_codes,omitempty"`

	// Payments is the account payment history displayed in the cabinet.
	Payments []PaymentEntry `json:"payments,omitempty"`
}

// PromoEntry is the store-level representation of a promo code.
// Kept separate from billing.Promo to avoid import cycles.
type PromoEntry struct {
	Code      string    `json:"code"`
	Type      string    `json:"type"` // "days" | "balance"
	Value     int       `json:"value"`
	MaxUses   int       `json:"max_uses"`
	UsedCount int       `json:"used_count"`
	ExpiresAt time.Time `json:"expires_at,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	Active    bool      `json:"active"`
}

// RedemptionEntry records a single promo redemption.
type RedemptionEntry struct {
	Code       string    `json:"code"`
	Username   string    `json:"username"`
	TelegramID int64     `json:"telegram_id"`
	RedeemedAt time.Time `json:"redeemed_at"`
}

// Account holds the Mosaic service billing state — the link between the
// local daemon and the Remnawave user record. Populated after the user
// links their Telegram account through the bot.
type Account struct {
	// TelegramID is the linking key. The user links the Flutter client to
	// their Remnawave account via @mosaicvpnbot; the bot issues a session
	// token that the daemon stores here.
	TelegramID int64 `json:"telegram_id,omitempty"`
	// SessionToken is the legacy opaque token issued by the bot. Empty when no
	// account is linked.
	SessionToken string `json:"session_token,omitempty"`
	// DirectToken is a separately scoped opaque credential for the personal
	// direct sing-box feed. It is not a Telegram ID and carries no user data.
	DirectToken string `json:"direct_token,omitempty"`
	// DirectFeedURL is the per-device subscription URL built from DirectToken.
	DirectFeedURL string `json:"direct_feed_url,omitempty"`
	// Username is the Remnawave username of the linked user, cached for
	// fast display when the daemon starts offline.
	Username string `json:"username,omitempty"`
	// Email is a non-secret display identity for password-based accounts.
	Email string `json:"email,omitempty"`
	// Cached profile fields — refreshed from Remnawave on demand.
	ExpireAt time.Time `json:"expire_at,omitempty"`
}

// Prefs holds user-configurable behaviour of the daemon.
type Prefs struct {
	TunnelMode          string   `json:"tunnel_mode"` // "tun" | "proxy"
	TunStack            string   `json:"tun_stack"`
	SocksAddr           string   `json:"socks_addr"`
	HTTPAddr            string   `json:"http_addr"`
	MixedPort           int      `json:"mixed_port"`
	MTU                 int      `json:"mtu"`
	KillSwitch          bool     `json:"kill_switch"`
	AllowLAN            bool     `json:"allow_lan"`
	BypassProcesses     []string `json:"bypass_processes,omitempty"`
	BlockIPv6           bool     `json:"block_ipv6"`
	DNSMode             string   `json:"dns_mode"` // "fake-ip" | "real-ip"
	DNSProxied          string   `json:"dns_proxied"`
	DNSDirect           string   `json:"dns_direct"`
	ShareLAN            bool     `json:"share_lan"`
	ShareAddr           string   `json:"share_addr"`
	ShareAllow          []string `json:"share_allow,omitempty"`
	AutoStart           string   `json:"auto_start"` // "service" | "user" | "manual"
	AutoConnect         bool     `json:"auto_connect"`
	ShowOnLaunch        bool     `json:"show_on_launch"`
	MCPEnabled          bool     `json:"mcp_enabled"`
	MCPAddr             string   `json:"mcp_addr"`
	MCPPermission       string   `json:"mcp_permission"` // "read" | "connect" | "full"
	MCPConfirm          bool     `json:"mcp_confirm"`
	ShowRawNodes        bool     `json:"show_raw_nodes"`
	AdvancedMode        bool     `json:"advanced_mode"`
	CompactMode         bool     `json:"compact_mode"`
	ThemeMode           string   `json:"theme_mode"`
	LastServerID        string   `json:"last_server_id"`
	FavoriteServerIDs   []string `json:"favorite_server_ids,omitempty"`
	MinimizeToTray      bool     `json:"minimize_to_tray"`
	AutoConnectEgresses bool     `json:"auto_connect_egresses"`
	TestURL             string   `json:"test_url"`
	AlwaysRunAsAdmin    bool     `json:"always_run_as_admin"`
}

// DefaultPrefs returns the prefs Mosaic ships with on a fresh install.
func DefaultPrefs() Prefs {
	return Prefs{
		TunnelMode:     "tun",
		SocksAddr:      "127.0.0.1:1080",
		HTTPAddr:       "127.0.0.1:1081",
		MTU:            1420,
		KillSwitch:     true,
		AllowLAN:       true,
		BlockIPv6:      false,
		DNSMode:        "fake-ip",
		DNSProxied:     "https://1.1.1.1/dns-query",
		DNSDirect:      "udp://77.88.8.8",
		ShareLAN:       false,
		ShareAddr:      "0.0.0.0:1080",
		AutoStart:      "service",
		AutoConnect:    true,
		ShowOnLaunch:   true,
		MinimizeToTray: true,
		MCPEnabled:     true,
		MCPAddr:        "127.0.0.1:8731",
		MCPPermission:  "connect",
		MCPConfirm:     true,
	}
}

// Default returns a State with sensible defaults.
func Default() State {
	return State{
		Prefs:             DefaultPrefs(),
		WARP:              proto.WARPConfig{},
		Version:           3,
		ProviderManifests: map[string]*proto.SubscriptionManifest{},
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
		seedDefaultGroups(&s.state)
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
	needsPersist := false
	if s.state.Prefs.SocksAddr == "" {
		s.state.Prefs = DefaultPrefs()
		needsPersist = true
	}
	// Version 2 establishes close-to-tray as the desktop default. This is a
	// one-time migration for pre-0.3.11 stores; subsequent user changes are
	// persisted normally and are not overwritten.
	if s.state.Version < 2 {
		s.state.Prefs.MinimizeToTray = true
		s.state.Version = 2
		needsPersist = true
	}
	if s.state.Profiles == nil {
		s.state.Profiles = []proto.Profile{}
	}
	if s.state.ProviderManifests == nil {
		s.state.ProviderManifests = map[string]*proto.SubscriptionManifest{}
		needsPersist = true
	}
	if s.state.CabinetBindings == nil {
		s.state.CabinetBindings = map[string]Account{}
		needsPersist = true
	}
	// Version 3 removed the `mosaic-direct` display name. Version 4 restores
	// the intended URL-first ownership model: a legacy feed remains a normal
	// local subscription while its private implementation pool stays hidden.
	if s.state.Version < 4 {
		for i := range s.state.Subscriptions {
			sub := &s.state.Subscriptions[i]
			if sub.ID == "mosaic-direct" ||
				(sub.Source == proto.SubscriptionSourceProvider && sub.ProviderID == "mosaicvpn") {
				sub.Source = proto.SubscriptionSourceURL
				sub.ProviderID = ""
				sub.ProviderAccountID = ""
				sub.HidePhysicalNodes = true
				if sub.Name == "" || sub.Name == "MosaicVPN · Direct" {
					sub.Name = "MosaicVPN"
				}
				if s.state.ActiveManifest != nil {
					s.state.ProviderManifests[sub.ID] = s.state.ActiveManifest
				}
				needsPersist = true
			}
		}
		s.state.Version = 4
		needsPersist = true
	}
	// Version 5 creates a binding only when the legacy account can be
	// assigned unambiguously to exactly one compatible URL source. Do not
	// guess when multiple Mosaic feeds exist on the device.
	if s.state.Version < 5 {
		if s.state.Account.DirectFeedURL != "" {
			matches := 0
			var id string
			for _, sub := range s.state.Subscriptions {
				if sub.URL == s.state.Account.DirectFeedURL {
					matches++
					id = sub.ID
				}
			}
			if matches == 1 {
				s.state.CabinetBindings[id] = s.state.Account
			}
		}
		s.state.Version = 5
		needsPersist = true
	}

	// Existing installs predate groups, so seed them here too rather than
	// only on a fresh file. Persist only when something was actually added.
	if seedDefaultGroups(&s.state) {
		needsPersist = true
	}
	if needsPersist {
		if err := s.persistLocked(); err != nil {
			return nil, err
		}
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
	cp.Profiles = append([]proto.Profile(nil), s.state.Profiles...)
	cp.RouteProfiles = append([]proto.RouteProfile(nil), s.state.RouteProfiles...)
	cp.ProviderAccounts = append([]proto.ProviderAccount(nil), s.state.ProviderAccounts...)
	if s.state.CabinetBindings != nil {
		cp.CabinetBindings = make(map[string]Account, len(s.state.CabinetBindings))
		for id, binding := range s.state.CabinetBindings {
			cp.CabinetBindings[id] = binding
		}
	}
	if s.state.ProviderManifests != nil {
		cp.ProviderManifests = make(map[string]*proto.SubscriptionManifest, len(s.state.ProviderManifests))
		for id, manifest := range s.state.ProviderManifests {
			if manifest == nil {
				continue
			}
			copy := *manifest
			copy.Groups = append([]proto.ManifestGroup(nil), manifest.Groups...)
			copy.DirectRoutes = append([]proto.ManifestGroup(nil), manifest.DirectRoutes...)
			copy.Rules = append([]proto.Rule(nil), manifest.Rules...)
			cp.ProviderManifests[id] = &copy
		}
	}
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
	// Strategy 1: write to tmp file + rename (atomic, preferred on Unix)
	if err := os.WriteFile(tmp, data, 0o600); err == nil {
		if err := os.Rename(tmp, s.path); err == nil {
			return nil
		}
		// Rename failed — try remove + rename (Windows often refuses rename
		// over an existing file that has restrictive ACL).
		_ = os.Remove(s.path)
		if err2 := os.Rename(tmp, s.path); err2 == nil {
			return nil
		}
		// Fall through to Strategy 2
		_ = os.Remove(tmp)
	}
	// Strategy 2: truncate-and-write the target file directly (works when
	// the file's ACL allows the current user to write but not create new
	// files in the directory).
	if f, err := os.OpenFile(s.path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600); err == nil {
		_, werr := f.Write(data)
		f.Close()
		if werr == nil {
			return nil
		}
	}
	// Strategy 3: remove the existing file (it may have been created by an
	// elevated process with a restrictive ACL) and write a fresh one.
	_ = os.Remove(s.path)
	if err := os.WriteFile(s.path, data, 0o600); err != nil {
		return fmt.Errorf("persist store: %w", err)
	}
	return nil
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
		// existing one. The user may legitimately add the same feed twice.
		// Keep a caller-provided ID for service-owned/local collections such
		// as mosaic-direct and local-default; only anonymous additions receive
		// a generated ID.
		if sub.ID == "" {
			sub.ID = fmt.Sprintf("sub-%d", time.Now().UnixNano())
		}
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

// ReorderSubscriptions persists a complete user-defined subscription order.
// The operation is deliberately all-or-nothing: clients must submit every
// current subscription exactly once, so a stale drag operation cannot silently
// drop a feed that was added in another window.
func (s *Store) ReorderSubscriptions(orderedIDs []string) error {
	return s.Update(func(st *State) error {
		if len(orderedIDs) != len(st.Subscriptions) {
			return fmt.Errorf("expected %d subscription IDs, got %d", len(st.Subscriptions), len(orderedIDs))
		}

		byID := make(map[string]proto.Subscription, len(st.Subscriptions))
		for _, sub := range st.Subscriptions {
			byID[sub.ID] = sub
		}

		reordered := make([]proto.Subscription, 0, len(orderedIDs))
		seen := make(map[string]struct{}, len(orderedIDs))
		for _, id := range orderedIDs {
			if _, duplicate := seen[id]; duplicate {
				return fmt.Errorf("duplicate subscription ID %q", id)
			}
			sub, ok := byID[id]
			if !ok {
				return fmt.Errorf("subscription %q not found", id)
			}
			seen[id] = struct{}{}
			reordered = append(reordered, sub)
		}
		st.Subscriptions = reordered
		return nil
	})
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

// SetServerGroup assigns a server to a group (stored as Tag).
// AddLocalServer saves a user-owned server in a local collection. Callers
// may provide a GroupID through Server.Tag; all group memberships are updated
// atomically with the server record.
func (s *Store) AddLocalServer(server proto.Server) (proto.Server, error) {
	var saved proto.Server
	err := s.Update(func(st *State) error {
		if server.ID == "" {
			server.ID = fmt.Sprintf("local-%d", time.Now().UnixNano())
		}
		if server.SubscriptionID == "" {
			server.SubscriptionID = "local-default"
		}
		if server.Name == "" {
			server.Name = fmt.Sprintf("%s %s", server.Protocol, server.Address)
		}
		if server.Raw == nil {
			server.Raw = map[string]any{}
		}
		for _, existing := range st.Servers {
			if existing.ID == server.ID {
				return fmt.Errorf("server %q already exists", server.ID)
			}
		}
		st.Servers = append(st.Servers, server)
		assignServerToGroup(st, server.ID, server.Tag)
		saved = server
		return nil
	})
	return saved, err
}

// DeleteServer removes one user-owned server and detaches it from any local
// group. Provider pool nodes cannot be deleted through this local operation.
func (s *Store) DeleteServer(id string) error {
	return s.Update(func(st *State) error {
		for i, server := range st.Servers {
			if server.ID != id {
				continue
			}
			if server.SubscriptionID == "mosaic-direct" {
				return fmt.Errorf("service pool nodes cannot be removed")
			}
			st.Servers = append(st.Servers[:i], st.Servers[i+1:]...)
			for gi := range st.Groups {
				st.Groups[gi].Nodes = removeNodeRef(st.Groups[gi].Nodes, id)
			}
			return nil
		}
		return fmt.Errorf("server %q not found", id)
	})
}

func (s *Store) SetServerGroup(id, groupID string) error {
	return s.Update(func(st *State) error {
		for i := range st.Servers {
			if st.Servers[i].ID == id {
				if st.Servers[i].SubscriptionID == "mosaic-direct" {
					return fmt.Errorf("service pool nodes cannot be placed in local groups")
				}
				if groupID != "" {
					found := false
					for _, group := range st.Groups {
						if group.ID == groupID && group.Source == proto.GroupSourceUser {
							found = true
							break
						}
					}
					if !found {
						return fmt.Errorf("local group %q not found", groupID)
					}
				}
				st.Servers[i].Tag = groupID
				assignServerToGroup(st, id, groupID)
				return nil
			}
		}
		return fmt.Errorf("server %q not found", id)
	})
}

func assignServerToGroup(st *State, serverID, groupID string) {
	for gi := range st.Groups {
		st.Groups[gi].Nodes = removeNodeRef(st.Groups[gi].Nodes, serverID)
	}
	if groupID == "" {
		return
	}
	for gi := range st.Groups {
		if st.Groups[gi].ID == groupID {
			st.Groups[gi].Nodes = append(st.Groups[gi].Nodes, proto.NodeRef{
				ServerID: serverID,
				Weight:   10,
				Alive:    true,
			})
			return
		}
	}
}

func removeNodeRef(nodes []proto.NodeRef, serverID string) []proto.NodeRef {
	out := nodes[:0]
	for _, node := range nodes {
		if node.ServerID != serverID {
			out = append(out, node)
		}
	}
	return out
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

// SetLastGroup remembers which group produced a working connection.
func (s *Store) SetLastGroup(id string) error {
	return s.Update(func(st *State) error {
		st.LastGroupID = id
		return nil
	})
}

// LastGroup returns the last group that produced a working connection.
func (s *Store) LastGroup() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state.LastGroupID
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

// SaveManifest retains the legacy global manifest view. New callers should
// use SaveManifestForSubscription so multiple provider accounts stay isolated.
func (s *Store) SaveManifest(m *proto.SubscriptionManifest) error {
	return s.Update(func(st *State) error {
		st.ActiveManifest = m
		return nil
	})
}

// SaveManifestForSubscription persists a provider manifest under the exact
// subscription that supplied it. The optional legacy view is kept in sync for
// older clients that still call GET /v1/manifest without a subscription ID.
func (s *Store) SaveManifestForSubscription(subscriptionID string, m *proto.SubscriptionManifest) error {
	if subscriptionID == "" || m == nil {
		return fmt.Errorf("subscription id and manifest required")
	}
	return s.Update(func(st *State) error {
		if st.ProviderManifests == nil {
			st.ProviderManifests = map[string]*proto.SubscriptionManifest{}
		}
		copy := *m
		copy.Groups = append([]proto.ManifestGroup(nil), m.Groups...)
		copy.Rules = append([]proto.Rule(nil), m.Rules...)
		st.ProviderManifests[subscriptionID] = &copy
		st.ActiveManifest = &copy
		return nil
	})
}

// ManifestForSubscription returns the provider manifest associated with one
// source. It intentionally does not fall back to an unrelated provider.
func (s *Store) ManifestForSubscription(subscriptionID string) *proto.SubscriptionManifest {
	s.mu.RLock()
	defer s.mu.RUnlock()
	manifest := s.state.ProviderManifests[subscriptionID]
	if manifest == nil {
		return nil
	}
	copy := *manifest
	copy.Groups = append([]proto.ManifestGroup(nil), manifest.Groups...)
	copy.DirectRoutes = append([]proto.ManifestGroup(nil), manifest.DirectRoutes...)
	copy.Rules = append([]proto.Rule(nil), manifest.Rules...)
	return &copy
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
		delete(st.ProviderManifests, subID)
		servers := make([]proto.Server, 0, len(st.Servers))
		for _, sv := range st.Servers {
			if sv.SubscriptionID != subID {
				servers = append(servers, sv)
			}
		}
		st.Servers = servers
		return nil
	})
}

// AddOrUpdateProfile stores or updates a profile. If p.ID is empty,
// generates a new ID in the format "profile-<nanos>" and initializes CreatedAt/UpdatedAt.
// On update, modifies the existing profile, updating its UpdatedAt timestamp.
func (s *Store) AddOrUpdateProfile(p proto.Profile) (proto.Profile, error) {
	var saved proto.Profile
	err := s.Update(func(st *State) error {
		now := time.Now().UTC()
		if p.ID == "" {
			p.ID = fmt.Sprintf("profile-%d", now.UnixNano())
			p.CreatedAt = now
			p.UpdatedAt = now
			st.Profiles = append(st.Profiles, p)
			saved = p
			return nil
		}
		for i, existing := range st.Profiles {
			if existing.ID == p.ID {
				if p.CreatedAt.IsZero() {
					p.CreatedAt = existing.CreatedAt
				}
				p.UpdatedAt = now
				st.Profiles[i] = p
				saved = p
				return nil
			}
		}
		if p.CreatedAt.IsZero() {
			p.CreatedAt = now
		}
		p.UpdatedAt = now
		st.Profiles = append(st.Profiles, p)
		saved = p
		return nil
	})
	return saved, err
}

// DeleteProfile removes a profile by id.
func (s *Store) DeleteProfile(id string) error {
	return s.Update(func(st *State) error {
		out := make([]proto.Profile, 0, len(st.Profiles))
		for _, p := range st.Profiles {
			if p.ID != id {
				out = append(out, p)
			}
		}
		st.Profiles = out
		if st.ActiveProfileID == id {
			st.ActiveProfileID = ""
		}
		return nil
	})
}

// SetActiveProfile sets the active profile ID.
func (s *Store) SetActiveProfile(id string) error {
	return s.Update(func(st *State) error {
		st.ActiveProfileID = id
		return nil
	})
}

// FindProfile returns the profile with the given ID, if it exists.
func (s *Store) FindProfile(id string) (proto.Profile, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, p := range s.state.Profiles {
		if p.ID == id {
			return p, true
		}
	}
	return proto.Profile{}, false
}

// AddOrUpdateRouteProfile stores or updates a route profile. If rp.ID is empty,
// generates a new ID in the format "route-<nanos>" and initializes CreatedAt/UpdatedAt.
// On update, modifies the existing route profile, updating its UpdatedAt timestamp.
func (s *Store) AddOrUpdateRouteProfile(rp proto.RouteProfile) (proto.RouteProfile, error) {
	var saved proto.RouteProfile
	err := s.Update(func(st *State) error {
		now := time.Now().UTC()
		if rp.ID == "" {
			rp.ID = fmt.Sprintf("route-%d", now.UnixNano())
			rp.CreatedAt = now
			rp.UpdatedAt = now
			st.RouteProfiles = append(st.RouteProfiles, rp)
			saved = rp
			return nil
		}
		for i, existing := range st.RouteProfiles {
			if existing.ID == rp.ID {
				if rp.CreatedAt.IsZero() {
					rp.CreatedAt = existing.CreatedAt
				}
				rp.UpdatedAt = now
				st.RouteProfiles[i] = rp
				saved = rp
				return nil
			}
		}
		if rp.CreatedAt.IsZero() {
			rp.CreatedAt = now
		}
		rp.UpdatedAt = now
		st.RouteProfiles = append(st.RouteProfiles, rp)
		saved = rp
		return nil
	})
	return saved, err
}

// DeleteRouteProfile removes a route profile by id.
func (s *Store) DeleteRouteProfile(id string) error {
	return s.Update(func(st *State) error {
		out := make([]proto.RouteProfile, 0, len(st.RouteProfiles))
		for _, rp := range st.RouteProfiles {
			if rp.ID != id {
				out = append(out, rp)
			}
		}
		st.RouteProfiles = out
		return nil
	})
}

// SetWARP stores the WARP configuration.
func (s *Store) SetWARP(w proto.WARPConfig) error {
	return s.Update(func(st *State) error {
		st.WARP = w
		return nil
	})
}

// GetWARP retrieves the WARP configuration.
func (s *Store) GetWARP() proto.WARPConfig {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state.WARP
}

// ---------- Billing / Account -----------------------------------------------

// GetAccount returns the linked Mosaic service account (or the zero value
// when no account is linked).
func (s *Store) GetAccount() Account {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state.Account
}

// SetAccount persists the linking state between the daemon and the
// Remnawave user record.
func (s *Store) SetAccount(a Account) error {
	return s.Update(func(st *State) error {
		st.Account = a
		return nil
	})
}

// GetCabinetBinding returns the optional cabinet credentials attached to one
// local subscription. A zero value means the URL source remains unbound.
func (s *Store) GetCabinetBinding(subscriptionID string) Account {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state.CabinetBindings[subscriptionID]
}

// SetCabinetBinding persists an optional provider cabinet attachment without
// modifying the URL subscription itself or the legacy global account.
func (s *Store) SetCabinetBinding(subscriptionID string, binding Account) error {
	return s.Update(func(st *State) error {
		if st.CabinetBindings == nil {
			st.CabinetBindings = map[string]Account{}
		}
		st.CabinetBindings[subscriptionID] = binding
		return nil
	})
}

// DeleteCabinetBinding is intentionally called alongside subscription removal
// so a deleted local URL source cannot leave cabinet credentials behind.
func (s *Store) DeleteCabinetBinding(subscriptionID string) error {
	return s.Update(func(st *State) error {
		delete(st.CabinetBindings, subscriptionID)
		return nil
	})
}

// ClearAccount unlinks the daemon from the Remnawave user.
func (s *Store) ClearAccount() error {
	return s.Update(func(st *State) error {
		st.Account = Account{}
		return nil
	})
}

// GetBillingCredentials returns the persisted Remnawave and CryptoBot
// credentials. All four strings are empty when no billing config has
// been saved.
func (s *Store) GetBillingCredentials() (remnawaveURL, remnawaveToken, cryptoBotURL, cryptoBotToken string) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state.RemnawaveURL, s.state.RemnawaveToken, s.state.CryptoBotURL, s.state.CryptoBotToken
}

// SetBillingCredentials persists the Remnawave and CryptoBot credentials
// used to rebuild the billing.Client on daemon restart.
func (s *Store) SetBillingCredentials(remnawaveURL, remnawaveToken, cryptoBotURL, cryptoBotToken string) error {
	return s.Update(func(st *State) error {
		st.RemnawaveURL = remnawaveURL
		st.RemnawaveToken = remnawaveToken
		st.CryptoBotURL = cryptoBotURL
		st.CryptoBotToken = cryptoBotToken
		return nil
	})
}

// GetYookassaCredentials returns the persisted YooKassa shop ID and secret key.
func (s *Store) GetYookassaCredentials() (shopID, secretKey string) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state.YookassaShopID, s.state.YookassaSecretKey
}

// SetYookassaCredentials persists the YooKassa credentials.
func (s *Store) SetYookassaCredentials(shopID, secretKey string) error {
	return s.Update(func(st *State) error {
		st.YookassaShopID = shopID
		st.YookassaSecretKey = secretKey
		return nil
	})
}

// ────────── Promo CRUD ──────────────────────────────────────────────

// ListPromos returns a copy of all promo codes.
func (s *Store) ListPromos() []PromoEntry {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]PromoEntry(nil), s.state.Promos...)
}

// GetPromo returns a promo by its normalized code, or nil.
func (s *Store) GetPromo(code string) *PromoEntry {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for i := range s.state.Promos {
		if s.state.Promos[i].Code == code {
			p := s.state.Promos[i] // copy
			return &p
		}
	}
	return nil
}

// AddPromo persists a new promo code.
func (s *Store) AddPromo(p PromoEntry) error {
	return s.Update(func(st *State) error {
		st.Promos = append(st.Promos, p)
		return nil
	})
}

// IncrementPromoUsage atomically increments UsedCount for a promo code.
func (s *Store) IncrementPromoUsage(code string) error {
	return s.Update(func(st *State) error {
		for i := range st.Promos {
			if st.Promos[i].Code == code {
				st.Promos[i].UsedCount++
				return nil
			}
		}
		return nil
	})
}

// HasRedeemed checks if a user (by telegram_id) already redeemed a promo.
func (s *Store) HasRedeemed(code string, telegramID int64) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, r := range s.state.Redemptions {
		if r.Code == code && r.TelegramID == telegramID {
			return true
		}
	}
	return false
}

// AddRedemption records a promo redemption.
func (s *Store) AddRedemption(r RedemptionEntry) error {
	return s.Update(func(st *State) error {
		st.Redemptions = append(st.Redemptions, r)
		return nil
	})
}

// ---------- Egress CRUD ----------------------------------------------------

// ListEgresses returns a copy of all egress listeners.
func (s *Store) ListEgresses() []proto.Egress {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]proto.Egress(nil), s.state.Egresses...)
}

// AddEgress inserts a new egress listener, assigning it a UUID.
func (s *Store) AddEgress(e proto.Egress) (proto.Egress, error) {
	e.ID = uuid()
	return e, s.Update(func(st *State) error {
		st.Egresses = append(st.Egresses, e)
		return nil
	})
}

// UpdateEgress replaces an existing egress by ID.
func (s *Store) UpdateEgress(e proto.Egress) error {
	return s.Update(func(st *State) error {
		for i, eg := range st.Egresses {
			if eg.ID == e.ID {
				st.Egresses[i] = e
				return nil
			}
		}
		return fmt.Errorf("egress %q not found", e.ID)
	})
}

// DeleteEgress removes an egress by ID.
func (s *Store) DeleteEgress(id string) error {
	return s.Update(func(st *State) error {
		out := make([]proto.Egress, 0, len(st.Egresses))
		for _, eg := range st.Egresses {
			if eg.ID != id {
				out = append(out, eg)
			}
		}
		st.Egresses = out
		return nil
	})
}

// ToggleEgress flips the active flag of an egress by ID.
func (s *Store) ToggleEgress(id string, active bool) error {
	return s.Update(func(st *State) error {
		for i := range st.Egresses {
			if st.Egresses[i].ID == id {
				st.Egresses[i].Active = active
				return nil
			}
		}
		return fmt.Errorf("egress %q not found", id)
	})
}

// ---------- Anti-DPI -------------------------------------------------------

// SetAntiDPI stores the anti-DPI configuration.
func (s *Store) SetAntiDPI(a proto.AntiDPIConfig) error {
	return s.Update(func(st *State) error {
		st.AntiDPI = a
		return nil
	})
}

// GetAntiDPI retrieves the anti-DPI configuration.
func (s *Store) GetAntiDPI() proto.AntiDPIConfig {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state.AntiDPI
}

// ---------- Export / Import ------------------------------------------------

// ExportState returns the full daemon state suitable for JSON export.
// When includeSubscriptions is false, subscription URLs are blanked.
func (s *Store) ExportState(includeSubscriptions bool) State {
	s.mu.RLock()
	defer s.mu.RUnlock()
	cp := s.state // shallow copy
	if !includeSubscriptions {
		subs := append([]proto.Subscription(nil), cp.Subscriptions...)
		for i := range subs {
			subs[i].URL = ""
		}
		cp.Subscriptions = subs
	}
	return cp
}

// ImportState merges or replaces the current state with the provided data.
// mode "replace" wipes the current state; "merge" (default) overwrites only
// the fields present in the import.
func (s *Store) ImportState(data State, mode string) error {
	return s.Update(func(st *State) error {
		if mode == "replace" {
			*st = data
			st.Version = 2
			return nil
		}
		// merge
		if len(data.Subscriptions) > 0 {
			st.Subscriptions = append(st.Subscriptions, data.Subscriptions...)
		}
		if len(data.Servers) > 0 {
			st.Servers = append(st.Servers, data.Servers...)
		}
		if len(data.Rules) > 0 {
			st.Rules = append(st.Rules, data.Rules...)
		}
		if len(data.Profiles) > 0 {
			st.Profiles = append(st.Profiles, data.Profiles...)
		}
		if len(data.RouteProfiles) > 0 {
			st.RouteProfiles = append(st.RouteProfiles, data.RouteProfiles...)
		}
		if len(data.Egresses) > 0 {
			st.Egresses = append(st.Egresses, data.Egresses...)
		}
		return nil
	})
}

// uuid generates a random hex ID for new records.
func uuid() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
