package state

import (
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

// Connect priority chain, per GROUP_SYSTEM_SPEC section 9:
//
//	1. explicit user choice   -> use it
//	2. last successful group  -> use it
//	3. pool-auto              -> pick by load
//	4. pool empty / all dead  -> emergency
//	5. emergency unavailable  -> honest error with a reason
//
// The rule that shapes this file: step 5 must never be a silent fall into an
// unknown state. Every failure path produces a *ResolveError carrying the
// reason and the steps that were tried, so the UI can show the user what went
// wrong and offer a retry instead of an empty spinner.

// ResolveStep names a link in the priority chain, for diagnostics.
type ResolveStep string

const (
	StepExplicit  ResolveStep = "explicit"
	StepLastGood  ResolveStep = "last_successful"
	StepPoolAuto  ResolveStep = "pool_auto"
	StepEmergency ResolveStep = "emergency"
)

// Resolution is the outcome of walking the priority chain.
type Resolution struct {
	// ServerID is the node to connect to.
	ServerID string
	// GroupID is the group the node came from.
	GroupID string
	// Step records which link produced the result.
	Step ResolveStep
	// Degraded is true when an earlier, more preferred step failed. The UI
	// surfaces this so a silent downgrade to emergency stays visible.
	Degraded bool
	// Notes explain any downgrade in user-facing language.
	Notes []string
}

// ResolveError reports that no node could be selected, and why. It deliberately
// carries structured detail: "connect failed" alone gives the user nothing to
// act on.
type ResolveError struct {
	// Reason is a short user-facing explanation.
	Reason string
	// Tried lists the steps attempted, in order.
	Tried []ResolveStep
	// Details holds per-step diagnostics.
	Details []string
	// Retryable is true when waiting and trying again may succeed.
	Retryable bool
}

func (e *ResolveError) Error() string {
	if len(e.Details) == 0 {
		return e.Reason
	}
	return fmt.Sprintf("%s (%s)", e.Reason, strings.Join(e.Details, "; "))
}

// ErrNoNodeAvailable matches any resolution failure via errors.Is.
var ErrNoNodeAvailable = errors.New("no node available")

func (e *ResolveError) Is(target error) bool { return target == ErrNoNodeAvailable }

// GroupSource is the subset of store behaviour the resolver needs. Keeping it
// narrow lets the chain be tested without a real store or daemon.
type GroupSource interface {
	Groups() []proto.ServerGroup
	Group(id string) (proto.ServerGroup, bool)
	LastGroup() string
	FindServer(id string) (proto.Server, bool)
}

// Resolve walks the priority chain and returns the node to connect to.
//
// explicitGroupID is the group the user picked in the UI; empty means "decide
// for me". explicitServerID pins one specific node, which short-circuits the
// whole chain — a manual pick is always honoured.
func Resolve(src GroupSource, explicitGroupID, explicitServerID string) (Resolution, error) {
	rerr := &ResolveError{Retryable: true}

	// A pinned node bypasses group logic entirely.
	if explicitServerID != "" {
		rerr.Tried = append(rerr.Tried, StepExplicit)
		if _, ok := src.FindServer(explicitServerID); ok {
			return Resolution{
				ServerID: explicitServerID,
				GroupID:  explicitGroupID,
				Step:     StepExplicit,
			}, nil
		}
		// A stale pin must not silently redirect the user elsewhere: they asked
		// for a specific server and deserve to know it is gone.
		rerr.Reason = "Выбранный сервер больше не доступен"
		rerr.Details = append(rerr.Details,
			fmt.Sprintf("сервер %q отсутствует в списке", explicitServerID))
		rerr.Retryable = false
		return Resolution{}, rerr
	}

	var notes []string

	// Step 1: explicit group.
	if explicitGroupID != "" {
		rerr.Tried = append(rerr.Tried, StepExplicit)
		g, ok := src.Group(explicitGroupID)
		if !ok {
			rerr.Reason = "Выбранная группа не найдена"
			rerr.Details = append(rerr.Details,
				fmt.Sprintf("группа %q отсутствует", explicitGroupID))
			rerr.Retryable = false
			return Resolution{}, rerr
		}
		if id, err := pickNode(src, g); err == nil {
			return Resolution{ServerID: id, GroupID: g.ID, Step: StepExplicit}, nil
		} else {
			// An explicit choice that cannot be served is worth reporting even
			// when a later step saves the connection.
			rerr.Details = append(rerr.Details, fmt.Sprintf("группа %q: %v", g.ID, err))
			notes = append(notes,
				fmt.Sprintf("В группе «%s» нет живых узлов", displayName(g)))
		}
	}

	// Step 2: last successful group.
	if last := src.LastGroup(); last != "" && last != explicitGroupID {
		rerr.Tried = append(rerr.Tried, StepLastGood)
		if g, ok := src.Group(last); ok {
			if id, err := pickNode(src, g); err == nil {
				return Resolution{
					ServerID: id,
					GroupID:  g.ID,
					Step:     StepLastGood,
					Degraded: len(notes) > 0,
					Notes:    notes,
				}, nil
			} else {
				rerr.Details = append(rerr.Details, fmt.Sprintf("последняя группа %q: %v", g.ID, err))
				notes = append(notes,
					fmt.Sprintf("Прошлая группа «%s» недоступна", displayName(g)))
			}
		} else {
			rerr.Details = append(rerr.Details,
				fmt.Sprintf("последняя группа %q больше не существует", last))
		}
	}

	// Step 3: pool-auto.
	if explicitGroupID != poolAutoID {
		rerr.Tried = append(rerr.Tried, StepPoolAuto)
		if g, ok := src.Group(poolAutoID); ok {
			if id, err := pickNode(src, g); err == nil {
				return Resolution{
					ServerID: id,
					GroupID:  g.ID,
					Step:     StepPoolAuto,
					Degraded: len(notes) > 0,
					Notes:    notes,
				}, nil
			} else {
				rerr.Details = append(rerr.Details, fmt.Sprintf("автоподбор: %v", err))
				notes = append(notes, "Автоподбор не нашёл живых узлов")
			}
		} else {
			rerr.Details = append(rerr.Details, "группа автоподбора отсутствует")
		}
	}

	// Step 4: emergency.
	rerr.Tried = append(rerr.Tried, StepEmergency)
	if g, ok := src.Group(emergencyID); ok {
		if id, err := pickNode(src, g); err == nil {
			notes = append(notes, "Используется аварийный узел")
			return Resolution{
				ServerID: id,
				GroupID:  g.ID,
				Step:     StepEmergency,
				Degraded: true,
				Notes:    notes,
			}, nil
		} else {
			rerr.Details = append(rerr.Details, fmt.Sprintf("аварийная группа: %v", err))
		}
	} else {
		rerr.Details = append(rerr.Details, "аварийная группа отсутствует")
	}

	// Step 5: honest error.
	rerr.Reason = "Нет доступных серверов для подключения"
	return Resolution{}, rerr
}

// Group IDs the chain depends on. Declared here rather than imported from the
// store to keep the resolver free of a store dependency.
const (
	poolAutoID  = "pool-auto"
	emergencyID = "emergency"
)

// pickNode chooses the best node inside a group: alive, known to the server
// list, lowest load-adjusted score. It mirrors the pool scoring formula so the
// resolver and the pool agree on what "best" means.
func pickNode(src GroupSource, g proto.ServerGroup) (string, error) {
	if len(g.Nodes) == 0 {
		return "", errors.New("группа пуста")
	}

	type cand struct {
		id    string
		score float64
	}
	var cands []cand
	var dead, unknown int

	for _, n := range g.Nodes {
		if !n.Alive {
			dead++
			continue
		}
		// A node the server list does not know about cannot be dialled. Skipping
		// it here avoids handing Connect an ID that fails immediately.
		if _, ok := src.FindServer(n.ServerID); !ok {
			unknown++
			continue
		}
		cands = append(cands, cand{id: n.ServerID, score: nodeScore(n)})
	}

	if len(cands) == 0 {
		return "", fmt.Errorf("нет живых узлов (мертвы: %d, неизвестны: %d)", dead, unknown)
	}

	// Deterministic order: score, then ID as a tiebreaker so repeated calls in
	// tests and in the UI do not flap between equal nodes.
	sort.Slice(cands, func(i, j int) bool {
		if cands[i].score != cands[j].score {
			return cands[i].score < cands[j].score
		}
		return cands[i].id < cands[j].id
	})
	return cands[0].id, nil
}

// nodeScore ranks a node; lower is better. Same shape as the pool formula:
// latency penalised by load, rewarded by weight.
func nodeScore(n proto.NodeRef) float64 {
	latency := float64(n.LatencyMs)
	if latency <= 0 {
		// Unprobed nodes are usable but should lose to any measured node.
		latency = 1000
	}
	weight := float64(n.Weight)
	if weight <= 0 {
		weight = 1
	}
	load := n.Load
	if load < 0 {
		load = 0
	}
	if load > 0.99 {
		load = 0.99
	}
	return latency / (weight * (1 - load))
}

func displayName(g proto.ServerGroup) string {
	if g.Title != "" {
		return g.Title
	}
	return g.ID
}
