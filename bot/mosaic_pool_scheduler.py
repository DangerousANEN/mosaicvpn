"""bot.mosaic_pool_scheduler — Low-resource candidate scheduling and state management.

Provides persisted candidate rotation, prioritization (overdue verified nodes &
country deficits), bounded exponential backoff with deterministic jitter, and
source-yield EWMA tracking for the MosaicVPN pool collector.
"""

from __future__ import annotations

import hashlib
import json
import logging
import math
import os
from pathlib import Path
import tempfile
from typing import Any, Dict, List, Mapping, Optional, Sequence, Set, Tuple

logger = logging.getLogger("mosaic_pool_scheduler")

# Default scheduler tuning constants
DEFAULT_BASE_COOLDOWN: float = 300.0          # 5 minutes
DEFAULT_MAX_COOLDOWN: float = 86400.0         # 24 hours
DEFAULT_COOLDOWN_JITTER: float = 0.2          # +/- 20%
DEFAULT_VERIFY_TTL: float = 7200.0            # 2 hours (re-check verified nodes)
# Tiered re-verify intervals (seconds). A single flat TTL either wastes budget
# on rock-solid nodes or lets degraded ones rot in the config; the tier is
# derived from per-node evidence in verify_ttl_for():
#   - NEW (first verification or <2 verifications): 1h trust-building period
#   - DEGRADED (recent failures after a success): 30m to catch recovery/stay
#     honest about flapping nodes
#   - HEALTHY (stable verified track record): 4h economical re-check
DEFAULT_TTL_NEW_SECONDS: float = 3600.0
DEFAULT_TTL_DEGRADED_SECONDS: float = 1800.0
DEFAULT_TTL_HEALTHY_SECONDS: float = 14400.0
DEFAULT_REFRESH_RATIO: float = 0.8            # Refresh verified candidates before TTL expiry (80% of TTL)
DEFAULT_MAX_REFRESH_RATIO: float = 0.7        # Refresh quota cap to protect discovery (70% of budget)
DEFAULT_MAX_DEFICIT_RATIO: float = 0.8        # Country deficit quota cap to protect exploration (80% of budget)
DEFAULT_PRUNE_TTL: float = 604800.0           # 7 days (prune unseen candidates)
DEFAULT_EWMA_ALPHA: float = 0.15              # Weight for new check in source yield
DEFAULT_MAX_CANDIDATES_IN_STATE: int = 50000  # Hard ceiling on tracked candidates

# Target countries and quotas matching collector auto/named groups
DEFAULT_TARGET_COUNTRIES: Tuple[str, ...] = (
    "DE", "NL", "US", "FR", "CA", "GB", "FI", "PL", "SG", "JP",
)
DEFAULT_COUNTRY_TARGET_QUOTA: int = 40
DEFAULT_COUNTRY_TARGETS: Dict[str, int] = {
    cc: DEFAULT_COUNTRY_TARGET_QUOTA for cc in DEFAULT_TARGET_COUNTRIES
}
DEFAULT_STATE_FILE: str = os.environ.get(
    "MOSAIC_SCHEDULER_STATE", "/var/lib/mosaic/scheduler_state.json"
)


def _safe_float(val: Any, default: float = 0.0) -> float:
    """Safely coerce any value to a finite float, falling back to default."""
    if val is None:
        return default
    try:
        f = float(val)
        return default if math.isnan(f) or math.isinf(f) else f
    except (ValueError, TypeError):
        return default


def _safe_int(val: Any, default: int = 0) -> int:
    """Safely coerce any value to an integer, falling back to default."""
    if val is None:
        return default
    try:
        return int(val)
    except (ValueError, TypeError):
        return default


def _safe_bool_or_none(val: Any) -> Optional[bool]:
    """Safely coerce to explicit True, False, or None."""
    if val is True:
        return True
    if val is False:
        return False
    return None


def verify_ttl_for(
    meta: Optional[Mapping[str, Any]],
    verify_ttl: float = DEFAULT_VERIFY_TTL,
    ttl_new: float = DEFAULT_TTL_NEW_SECONDS,
    ttl_degraded: float = DEFAULT_TTL_DEGRADED_SECONDS,
    ttl_healthy: float = DEFAULT_TTL_HEALTHY_SECONDS,
) -> float:
    """Per-node re-verify interval derived from observed evidence.

    Tier rules (the flat `verify_ttl` acts as an overall ceiling/fallback):
    - NEW: node was verified fewer than 2 times total -> `ttl_new` (1h).
      Fresh nodes have no trust record yet; the trust-building period keeps
      flaky free nodes out of the client feed until they prove themselves.
    - DEGRADED: currently healthy (last check ok) but has >=2 total failures
      recorded -> `ttl_degraded` (30m). Flapping nodes need frequent
      re-verification to catch the next outage fast.
    - HEALTHY: verified >=2 times, currently ok, little failure history
      -> `ttl_healthy` (4h). Stable nodes do not need aggressive re-checking.
    - Any returned value is capped at `verify_ttl` when that is smaller
      (callers may lower the global ceiling via env/args), and is always > 0.
    """
    ttl_new = max(60.0, _safe_float(ttl_new, default=DEFAULT_TTL_NEW_SECONDS))
    ttl_degraded = max(60.0, _safe_float(ttl_degraded, default=DEFAULT_TTL_DEGRADED_SECONDS))
    ttl_healthy = max(60.0, _safe_float(ttl_healthy, default=DEFAULT_TTL_HEALTHY_SECONDS))
    ceiling = _safe_float(verify_ttl, default=DEFAULT_VERIFY_TTL)

    if not isinstance(meta, Mapping) or meta.get("proxy_ok") is not True:
        # Not currently verified: trust-building applies (NEW tier).
        result = ttl_new
    else:
        verifications = _safe_int(meta.get("verification_count"), default=0)
        total_fails = _safe_int(meta.get("failure_count"), default=0) + _safe_int(
            meta.get("consecutive_fails"), default=0
        )
        if verifications < 2:
            result = ttl_new
        elif total_fails >= 2:
            result = ttl_degraded
        else:
            result = ttl_healthy

    # A smaller global ceiling never lengthens a tier, but tier upgrades
    # (HEALTHY 4h > old flat 2h) are intentional budget savings, so the
    # ceiling only clamps tiers that are LONGER than it when the caller
    # explicitly lowered it below the default flat TTL.
    default_ceiling = DEFAULT_VERIFY_TTL
    if 0 < ceiling < default_ceiling:
        result = min(result, ceiling)
    return max(60.0, result)


def tiered_verify_ttl(
    meta: Optional[Mapping[str, Any]],
    verify_ttl: float = DEFAULT_VERIFY_TTL,
) -> float:
    """Backwards-compatible wrapper using the default tier constants."""
    return verify_ttl_for(meta, verify_ttl=verify_ttl)


def compute_cooldown(
    fingerprint: str,
    consecutive_fails: int,
    base_cooldown: float = DEFAULT_BASE_COOLDOWN,
    max_cooldown: float = DEFAULT_MAX_COOLDOWN,
    jitter_ratio: float = DEFAULT_COOLDOWN_JITTER,
) -> float:
    """Calculate bounded exponential backoff with deterministic pseudo-random jitter.
    
    Jitter is derived deterministically from the SHA-256 digest of (fingerprint, consecutive_fails),
    preventing synchronized retry thundering herds while remaining completely deterministic
    for repeatable simulation and testing.
    """
    if consecutive_fails <= 0:
        return 0.0

    exponent = min(consecutive_fails - 1, 16)
    nominal = min(max_cooldown, base_cooldown * (2.0 ** exponent))

    seed_str = f"{fingerprint}:{consecutive_fails}:cooldown_jitter"
    digest = hashlib.sha256(seed_str.encode("utf-8")).hexdigest()
    # Normalize the first 8 hex chars to [0.0, 1.0]
    ratio = int(digest[:8], 16) / 0xFFFFFFFF
    jitter_factor = 1.0 + (2.0 * ratio - 1.0) * jitter_ratio

    cooldown = nominal * jitter_factor
    return max(0.0, min(max_cooldown, cooldown))


def _extract_node_meta(node: Any) -> Tuple[str, str, Optional[str]]:
    """Safely extract (fingerprint, source_name, country_code) from a Node or dict.
    
    Prefers detected exit_country_code over declared country_code when available.
    """
    if isinstance(node, Mapping):
        fp = str(node.get("fingerprint") or "").strip()
        src = str(node.get("source_name") or "unknown").strip()
        cc = node.get("exit_country_code") or node.get("country_code")
    else:
        fp = str(getattr(node, "fingerprint", "") or "").strip()
        src = str(getattr(node, "source_name", "unknown") or "unknown").strip()
        cc = getattr(node, "exit_country_code", None) or getattr(node, "country_code", None)

    cc_str = str(cc).strip().upper() if cc else None
    return fp, src, cc_str


def _extract_probe_results(node: Any) -> Tuple[str, str, Optional[str], Optional[bool], Optional[bool]]:
    """Safely extract (fingerprint, source_name, country_code, tcp_ok, proxy_ok)."""
    fp, src, cc = _extract_node_meta(node)
    if isinstance(node, Mapping):
        tcp_ok = node.get("tcp_ok")
        proxy_ok = node.get("proxy_ok")
    else:
        tcp_ok = getattr(node, "tcp_ok", None)
        proxy_ok = getattr(node, "proxy_ok", None)

    return fp, src, cc, tcp_ok, proxy_ok


def init_scheduler_state() -> Dict[str, Any]:
    """Return an empty scheduler state structure."""
    return {
        "version": 1,
        "updated_at": 0.0,
        "exploration_cursor": 0,
        "sources": {},
        "candidates": {},
    }


def sanitize_state(state: Any) -> Dict[str, Any]:
    """Sanitize and normalize persisted state, recovering robustly from malformed types."""
    if not isinstance(state, dict):
        return init_scheduler_state()

    version = _safe_int(state.get("version"), default=1)
    updated_at = _safe_float(state.get("updated_at"), default=0.0)
    cursor = max(0, _safe_int(state.get("exploration_cursor"), default=0))

    raw_sources = state.get("sources")
    clean_sources: Dict[str, Any] = {}
    if isinstance(raw_sources, dict):
        for src, smeta in raw_sources.items():
            if not isinstance(smeta, dict):
                clean_sources[str(src)] = {
                    "ewma_yield": 0.5,
                    "checks_count": 0,
                    "success_count": 0,
                }
            else:
                clean_sources[str(src)] = {
                    "ewma_yield": max(0.0, min(1.0, _safe_float(smeta.get("ewma_yield"), default=0.5))),
                    "checks_count": max(0, _safe_int(smeta.get("checks_count"), default=0)),
                    "success_count": max(0, _safe_int(smeta.get("success_count"), default=0)),
                }

    raw_candidates = state.get("candidates")
    clean_candidates: Dict[str, Any] = {}
    if isinstance(raw_candidates, dict):
        for fp, cmeta in raw_candidates.items():
            fp_str = str(fp).strip()
            if not fp_str or not isinstance(cmeta, dict):
                continue
            cc = cmeta.get("country_code")
            cc_str = str(cc).strip().upper() if cc else None
            last_checked = _safe_float(cmeta.get("last_checked_at")) if cmeta.get("last_checked_at") is not None else None
            last_verified = _safe_float(cmeta.get("last_verified_at")) if cmeta.get("last_verified_at") is not None else None
            clean_candidates[fp_str] = {
                "source_name": str(cmeta.get("source_name") or "unknown").strip(),
                "country_code": cc_str,
                "consecutive_fails": max(0, _safe_int(cmeta.get("consecutive_fails"), default=0)),
                "cooldown_until": max(0.0, _safe_float(cmeta.get("cooldown_until"), default=0.0)),
                "last_seen_at": max(0.0, _safe_float(cmeta.get("last_seen_at"), default=0.0)),
                "last_scheduled_at": max(0.0, _safe_float(cmeta.get("last_scheduled_at"), default=0.0)),
                "last_checked_at": last_checked,
                "last_verified_at": last_verified,
                "proxy_ok": _safe_bool_or_none(cmeta.get("proxy_ok")),
                # Tiered-TTL evidence (missing -> 0, tiers degrade gracefully)
                "verification_count": max(0, _safe_int(cmeta.get("verification_count"), default=0)),
                "failure_count": max(0, _safe_int(cmeta.get("failure_count"), default=0)),
            }

    return {
        "version": version,
        "updated_at": updated_at,
        "exploration_cursor": cursor,
        "sources": clean_sources,
        "candidates": clean_candidates,
    }


def prune_state(
    state: Dict[str, Any],
    now: float,
    prune_ttl: float = DEFAULT_PRUNE_TTL,
    max_candidates: int = DEFAULT_MAX_CANDIDATES_IN_STATE,
) -> None:
    """Prune stale candidate entries from state to keep memory and disk bounded.
    
    Candidates not seen within `prune_ttl` seconds are dropped unless currently verified.
    If total size still exceeds `max_candidates`, oldest candidates are evicted.
    """
    if not isinstance(state, dict):
        return
    candidates = state.setdefault("candidates", {})
    if not isinstance(candidates, dict):
        state["candidates"] = {}
        return

    stale_fps = []
    for fp, meta in candidates.items():
        if not isinstance(meta, dict):
            stale_fps.append(fp)
            continue
        last_seen = _safe_float(meta.get("last_seen_at"), default=0.0)
        is_verified = bool(meta.get("proxy_ok") is True)
        if not is_verified and (now - last_seen > prune_ttl):
            stale_fps.append(fp)

    for fp in stale_fps:
        candidates.pop(fp, None)

    if len(candidates) > max_candidates:
        # Sort candidates by (is_verified, last_seen_at) ascending to evict least valuable first
        sorted_items = sorted(
            candidates.items(),
            key=lambda item: (
                1 if (isinstance(item[1], dict) and item[1].get("proxy_ok") is True) else 0,
                _safe_float(item[1].get("last_seen_at") if isinstance(item[1], dict) else 0.0, default=0.0),
            ),
        )
        excess = len(candidates) - max_candidates
        for fp, _ in sorted_items[:excess]:
            candidates.pop(fp, None)


def schedule_candidates(
    nodes: Sequence[Any],
    total_limit: int,
    state: Dict[str, Any],
    now: float,
    country_targets: Optional[Mapping[str, int]] = None,
    verify_ttl: float = DEFAULT_VERIFY_TTL,
    base_cooldown: float = DEFAULT_BASE_COOLDOWN,
    max_cooldown: float = DEFAULT_MAX_COOLDOWN,
    refresh_ratio: float = DEFAULT_REFRESH_RATIO,
    max_deficit_ratio: float = DEFAULT_MAX_DEFICIT_RATIO,
    max_refresh_ratio: float = DEFAULT_MAX_REFRESH_RATIO,
    record_scheduled: bool = True,
) -> List[Any]:
    """Select a prioritized, deduplicated, rate-limited subset of candidate nodes.
    
    Guarantees:
    - Hard budget ceiling: Never returns more than `total_limit` items.
    - Zero or negative limit returns empty list immediately.
    - Deduplication: Each canonical fingerprint is scheduled at most once per cycle.
    - Cooldown enforcement: Candidates within active backoff cooldown are skipped.
    - Priority 1: Verified nodes overdue for refresh before TTL expiry.
    - Priority 2: Country deficits against `country_targets` (budget bounded to prevent exploration starvation).
    - Priority 3: Rotating exploration across sources (preventing low-yield starvation).
    - Exploration rotates deterministically across runs instead of repeating feed-prefixes.
    - Parameter `record_scheduled`: controls whether `last_scheduled_at` and `exploration_cursor` are mutated,
      preventing multi-stage scheduling calls from distorting subsequent rotation.
    """
    if total_limit <= 0 or not nodes:
        return []

    if not isinstance(state, dict):
        return []

    candidates_state = state.setdefault("candidates", {})
    if not isinstance(candidates_state, dict):
        candidates_state = state["candidates"] = {}

    sources_state = state.setdefault("sources", {})
    if not isinstance(sources_state, dict):
        sources_state = state["sources"] = {}

    # 1. Deduplicate input nodes by canonical fingerprint
    unique_nodes: Dict[str, Any] = {}
    for node in nodes:
        fp, src, cc = _extract_node_meta(node)
        if not fp:
            continue
        existing = unique_nodes.get(fp)
        if existing is None:
            unique_nodes[fp] = node
        elif cc and not _extract_node_meta(existing)[2]:
            # Prefer copy with country metadata if available
            unique_nodes[fp] = node

    if not unique_nodes:
        return []

    # 2. Touch/refresh last_seen_at for all incoming nodes in state
    for fp, node in unique_nodes.items():
        _, src, cc = _extract_node_meta(node)
        cand_meta = candidates_state.setdefault(fp, {
            "source_name": src,
            "country_code": cc,
            "consecutive_fails": 0,
            "cooldown_until": 0.0,
            "last_seen_at": now,
            "last_scheduled_at": 0.0,
            "last_checked_at": None,
            "last_verified_at": None,
            "proxy_ok": None,
        })
        if not isinstance(cand_meta, dict):
            cand_meta = candidates_state[fp] = {
                "source_name": src,
                "country_code": cc,
                "consecutive_fails": 0,
                "cooldown_until": 0.0,
                "last_seen_at": now,
                "last_scheduled_at": 0.0,
                "last_checked_at": None,
                "last_verified_at": None,
                "proxy_ok": None,
            }
        cand_meta["last_seen_at"] = now
        if src and not cand_meta.get("source_name"):
            cand_meta["source_name"] = src
        if cc and not cand_meta.get("country_code"):
            cand_meta["country_code"] = cc

    # 3. Filter candidates: exclude those under active cooldown
    eligible_nodes: Dict[str, Any] = {}
    for fp, node in unique_nodes.items():
        meta = candidates_state.get(fp, {})
        cooldown_until = _safe_float(meta.get("cooldown_until") if isinstance(meta, dict) else 0.0, default=0.0)
        if cooldown_until > now:
            # Candidate is currently in backoff cooldown
            continue
        eligible_nodes[fp] = node

    scheduled: List[Any] = []
    scheduled_fps: Set[str] = set()

    def _schedule_node(candidate: Any) -> bool:
        if len(scheduled) >= total_limit:
            return False
        fp, _, _ = _extract_node_meta(candidate)
        if fp in scheduled_fps:
            return False
        scheduled.append(candidate)
        scheduled_fps.add(fp)
        if record_scheduled:
            meta = candidates_state.setdefault(fp, {})
            if isinstance(meta, dict):
                meta["last_scheduled_at"] = now
        return True

    # ── Tier 1: Overdue Previously Verified / Reserve Nodes ────────────────────
    # Refresh nodes before TTL expiry to maintain healthy pool reserve
    effective_refresh_ratio = max(0.0, min(1.0, _safe_float(refresh_ratio, default=DEFAULT_REFRESH_RATIO)))
    refresh_threshold = verify_ttl * effective_refresh_ratio

    overdue_fps: Set[str] = set()
    verified_overdue: List[Tuple[float, Any]] = []
    for fp, node in eligible_nodes.items():
        meta = candidates_state.get(fp, {})
        if isinstance(meta, dict) and meta.get("proxy_ok") is True:
            last_ver = _safe_float(meta.get("last_verified_at"), default=0.0)
            node_ttl = verify_ttl_for(meta, verify_ttl=verify_ttl)
            node_refresh_threshold = node_ttl * effective_refresh_ratio
            if (now - last_ver) >= node_refresh_threshold:
                verified_overdue.append((last_ver, node))
                overdue_fps.add(fp)
    _ = refresh_threshold  # kept for API compatibility (flat-TTL path no longer used)

    # Oldest verified first
    verified_overdue.sort(key=lambda x: x[0])

    # Cap overdue refresh to prevent starving discovery/country deficits when other candidates exist
    effective_max_refresh = max(0.1, min(1.0, _safe_float(max_refresh_ratio, default=DEFAULT_MAX_REFRESH_RATIO)))
    has_non_refresh = len(overdue_fps) < len(eligible_nodes)
    if has_non_refresh and total_limit >= 2:
        refresh_ceiling = max(1, int(math.floor(total_limit * effective_max_refresh)))
    else:
        refresh_ceiling = total_limit

    for _, node in verified_overdue:
        if len(scheduled) >= refresh_ceiling:
            break
        _schedule_node(node)

    if len(scheduled) >= total_limit:
        return scheduled

    # ── Tier 2: Country Deficit Allocation ────────────────────────────────────
    by_country: Dict[str, List[Any]] = {}
    deficits: Dict[str, int] = {}
    if country_targets:
        # Count currently active verified nodes per country in state (fresh, current, and not in cooldown)
        healthy_counts: Dict[str, int] = {}
        for fp, meta in candidates_state.items():
            if isinstance(meta, dict) and meta.get("proxy_ok") is True:
                last_ver = _safe_float(meta.get("last_verified_at"), default=0.0)
                last_seen = _safe_float(meta.get("last_seen_at"), default=0.0)
                cooldown_until = _safe_float(meta.get("cooldown_until"), default=0.0)
                consecutive_fails = _safe_int(meta.get("consecutive_fails"), default=0)
                # Must be verified within its own tiered TTL, not stale in feeds,
                # not failed, and cooldown expired
                if (
                    (now - last_ver) < verify_ttl_for(meta, verify_ttl=verify_ttl)
                    and (now - last_seen) < verify_ttl
                    and consecutive_fails == 0
                    and cooldown_until <= now
                ):
                    cc = meta.get("exit_country_code") or meta.get("country_code")
                    if cc:
                        cc_upper = str(cc).strip().upper()
                        healthy_counts[cc_upper] = healthy_counts.get(cc_upper, 0) + 1

        # Calculate deficits
        for target_cc, target_count in country_targets.items():
            cc_upper = target_cc.upper()
            deficit = max(0, _safe_int(target_count, default=0) - healthy_counts.get(cc_upper, 0))
            if deficit > 0:
                deficits[cc_upper] = deficit

        if deficits:
            # Group unallocated non-overdue eligible nodes by country
            for fp, node in eligible_nodes.items():
                if fp in scheduled_fps or fp in overdue_fps:
                    continue
                _, _, cc = _extract_node_meta(node)
                if cc and cc in deficits:
                    by_country.setdefault(cc, []).append(node)

            # Prevent country deficits from completely consuming exploration budget when total_limit >= 5
            # For small limits (< 5), deficits can take the full budget to fulfill exact quota priorities
            effective_deficit_ratio = max(0.1, min(1.0, _safe_float(max_deficit_ratio, default=DEFAULT_MAX_DEFICIT_RATIO)))
            if total_limit >= 5 and any(fp not in scheduled_fps and fp not in overdue_fps for fp in eligible_nodes):
                min_exploration = max(1, int(math.floor(total_limit * (1.0 - effective_deficit_ratio))))
                deficit_ceiling = max(1, total_limit - min_exploration)
            else:
                deficit_ceiling = total_limit

            # Prioritize countries with highest deficits, filling up to deficit within deficit_ceiling
            for cc in sorted(deficits.keys(), key=lambda c: deficits[c], reverse=True):
                if len(scheduled) >= deficit_ceiling:
                    break
                needed = deficits[cc]
                available = by_country.get(cc, [])
                for node in available:
                    if needed <= 0 or len(scheduled) >= deficit_ceiling:
                        break
                    if _schedule_node(node):
                        needed -= 1

    if len(scheduled) >= total_limit:
        return scheduled

    # ── Tier 3: Deterministic Rotating Exploration ────────────────────────────
    # Partition remaining non-overdue candidates by source to prevent starvation
    remaining_by_source: Dict[str, List[Any]] = {}
    for fp, node in eligible_nodes.items():
        if fp in scheduled_fps or fp in overdue_fps:
            continue
        _, src, _ = _extract_node_meta(node)
        remaining_by_source.setdefault(src, []).append(node)

    if not remaining_by_source:
        # If no exploration candidates exist, fill any remaining slots from deficit leftovers
        if country_targets and deficits and len(scheduled) < total_limit:
            for cc in sorted(deficits.keys(), key=lambda c: deficits[c], reverse=True):
                if len(scheduled) >= total_limit:
                    break
                available = by_country.get(cc, [])
                for node in available:
                    if len(scheduled) >= total_limit:
                        break
                    _schedule_node(node)
        # Backfill remaining capacity with overdue nodes to prevent wasted budget
        if len(scheduled) < total_limit:
            for _, node in verified_overdue:
                if len(scheduled) >= total_limit:
                    break
                _schedule_node(node)
        return scheduled

    # Stable deterministic ordering of candidates within each source:
    # Sort by (last_scheduled_at ascending, hash of fingerprint for rotation)
    for src, src_nodes in remaining_by_source.items():
        src_nodes.sort(
            key=lambda n: (
                _safe_float(
                    candidates_state.get(_extract_node_meta(n)[0], {}).get("last_scheduled_at")
                    if isinstance(candidates_state.get(_extract_node_meta(n)[0]), dict) else 0.0,
                    default=0.0,
                ),
                hashlib.sha256(_extract_node_meta(n)[0].encode("utf-8")).hexdigest(),
            )
        )

    # Round-robin rotate across sources starting from persistent exploration cursor
    source_list = sorted(remaining_by_source.keys())
    cursor = _safe_int(state.get("exploration_cursor"), default=0) % max(1, len(source_list))

    # Reorder sources starting from cursor
    rotated_sources = source_list[cursor:] + source_list[:cursor]

    # Weighted round-robin: each source gets a floor of at least 1 candidate per round
    # (guaranteeing no starvation even if EWMA yield is low), with additional candidates
    # proportional to source yield EWMA.
    source_weights: Dict[str, int] = {}
    for src in rotated_sources:
        s_meta = sources_state.get(src, {})
        ewma = _safe_float(
            s_meta.get("ewma_yield") if isinstance(s_meta, dict) and s_meta.get("ewma_yield") is not None else 0.5,
            default=0.5,
        )
        # Weight between 1 and 4, ensuring non-zero floor for all sources
        source_weights[src] = max(1, min(4, int(round(ewma * 3)) + 1))

    # Multi-round fair round-robin scheduling (1 candidate per source per step)
    # up to each source's weight, preventing any single source from monopolizing
    allocated_counts: Dict[str, int] = {src: 0 for src in rotated_sources}
    any_added = True
    while any_added and len(scheduled) < total_limit:
        any_added = False
        for src in rotated_sources:
            if len(scheduled) >= total_limit:
                break
            weight = source_weights.get(src, 1)
            if allocated_counts[src] >= weight:
                continue
            src_candidates = remaining_by_source.get(src, [])
            if src_candidates:
                candidate = src_candidates.pop(0)
                if _schedule_node(candidate):
                    allocated_counts[src] += 1
                    any_added = True

        # If all sources reached their weight budget but total_limit is not full,
        # reset allocated_counts for another round
        if not any_added and len(scheduled) < total_limit and any(remaining_by_source.values()):
            allocated_counts = {src: 0 for src in rotated_sources}
            any_added = True

    # Advance exploration cursor for next cycle ONLY when record_scheduled is True
    if record_scheduled:
        state["exploration_cursor"] = (cursor + 1) % max(1, len(source_list))

    # Backfill remaining capacity with overdue nodes if exploration ran out of candidates
    if len(scheduled) < total_limit:
        for _, node in verified_overdue:
            if len(scheduled) >= total_limit:
                break
            _schedule_node(node)

    return scheduled


def update_state(
    state: Dict[str, Any],
    checked_nodes: Sequence[Any],
    now: float,
    ewma_alpha: float = DEFAULT_EWMA_ALPHA,
    base_cooldown: float = DEFAULT_BASE_COOLDOWN,
    max_cooldown: float = DEFAULT_MAX_COOLDOWN,
    prune_ttl: float = DEFAULT_PRUNE_TTL,
) -> Dict[str, Any]:
    """Update scheduler state with results from probe checks.
    
    Rules:
    - `proxy_ok is True`:
        - Reset consecutive failure counter to 0.
        - Set `last_verified_at = now`.
        - Clear cooldown (`cooldown_until = 0.0`).
        - Update source EWMA yield with sample=1.0.
    - `proxy_ok is False`:
        - Increment consecutive failure counter.
        - Calculate bounded exponential cooldown with deterministic jitter.
        - Update source EWMA yield with sample=0.0.
    - `proxy_ok is None` (untested/unknown):
        - CRITICAL: Never advance failure counters, cooldown, or source EWMA yield.
        - Preserves existing evidence without inventing failure or success.
    """
    if not isinstance(state, dict):
        return init_scheduler_state()

    candidates_state = state.setdefault("candidates", {})
    if not isinstance(candidates_state, dict):
        candidates_state = state["candidates"] = {}

    sources_state = state.setdefault("sources", {})
    if not isinstance(sources_state, dict):
        sources_state = state["sources"] = {}

    for node in checked_nodes:
        fp, src, cc, tcp_ok, proxy_ok = _extract_probe_results(node)
        if not fp:
            continue

        meta = candidates_state.setdefault(fp, {
            "source_name": src,
            "country_code": cc,
            "consecutive_fails": 0,
            "cooldown_until": 0.0,
            "last_seen_at": now,
            "last_scheduled_at": 0.0,
            "last_checked_at": None,
            "last_verified_at": None,
            "proxy_ok": None,
        })
        if not isinstance(meta, dict):
            meta = candidates_state[fp] = {
                "source_name": src,
                "country_code": cc,
                "consecutive_fails": 0,
                "cooldown_until": 0.0,
                "last_seen_at": now,
                "last_scheduled_at": 0.0,
                "last_checked_at": None,
                "last_verified_at": None,
                "proxy_ok": None,
            }

        meta["last_checked_at"] = now
        if src and not meta.get("source_name"):
            meta["source_name"] = src
        if cc:
            meta["country_code"] = cc

        # Only update proxy verification and source yield on ACTUAL proxy checks
        if proxy_ok is True:
            meta["proxy_ok"] = True
            meta["consecutive_fails"] = 0
            meta["cooldown_until"] = 0.0
            meta["last_verified_at"] = now
            # Tiered-TTL evidence: count lifetime verifications and failures.
            meta["verification_count"] = _safe_int(meta.get("verification_count"), default=0) + 1
            meta["failure_count"] = max(0, _safe_int(meta.get("failure_count"), default=0))

            # Update source yield EWMA
            s_meta = sources_state.setdefault(src, {
                "ewma_yield": 0.5,
                "checks_count": 0,
                "success_count": 0,
            })
            if not isinstance(s_meta, dict):
                s_meta = sources_state[src] = {
                    "ewma_yield": 0.5,
                    "checks_count": 0,
                    "success_count": 0,
                }
            s_meta["checks_count"] = _safe_int(s_meta.get("checks_count"), default=0) + 1
            s_meta["success_count"] = _safe_int(s_meta.get("success_count"), default=0) + 1
            curr_ewma = _safe_float(s_meta.get("ewma_yield") if s_meta.get("ewma_yield") is not None else 0.5, default=0.5)
            s_meta["ewma_yield"] = (1.0 - ewma_alpha) * curr_ewma + ewma_alpha * 1.0

        elif proxy_ok is False:
            meta["proxy_ok"] = False
            fails = _safe_int(meta.get("consecutive_fails"), default=0) + 1
            meta["consecutive_fails"] = fails
            # Tiered-TTL evidence: lifetime failure tally for DEGRADED tier.
            meta["failure_count"] = _safe_int(meta.get("failure_count"), default=0) + 1
            cd = compute_cooldown(
                fp,
                fails,
                base_cooldown=base_cooldown,
                max_cooldown=max_cooldown,
            )
            meta["cooldown_until"] = now + cd

            # Update source yield EWMA
            s_meta = sources_state.setdefault(src, {
                "ewma_yield": 0.5,
                "checks_count": 0,
                "success_count": 0,
            })
            if not isinstance(s_meta, dict):
                s_meta = sources_state[src] = {
                    "ewma_yield": 0.5,
                    "checks_count": 0,
                    "success_count": 0,
                }
            s_meta["checks_count"] = _safe_int(s_meta.get("checks_count"), default=0) + 1
            curr_ewma = _safe_float(s_meta.get("ewma_yield") if s_meta.get("ewma_yield") is not None else 0.5, default=0.5)
            s_meta["ewma_yield"] = (1.0 - ewma_alpha) * curr_ewma + ewma_alpha * 0.0

        else:
            # proxy_ok is None: untested or TCP-only.
            # Do NOT update proxy failure counter, cooldown, or source EWMA.
            pass

    state["updated_at"] = now
    prune_state(state, now, prune_ttl=prune_ttl)
    return state


# ── Atomic State Persistence Helpers ─────────────────────────────────────────

def load_state(path: str | Path) -> Dict[str, Any]:
    """Load scheduler state from JSON file. Returns fresh state if missing or corrupted."""
    target_path = Path(path)
    if target_path.exists():
        try:
            with open(target_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                return sanitize_state(data)
        except Exception as exc:
            logger.warning(f"Failed to read scheduler state from {target_path}: {exc}")
    return init_scheduler_state()


def save_state(path: str | Path, state: Dict[str, Any]) -> None:
    """Atomically save scheduler state to JSON file using safe temp-file replacement.
    
    Guarantees no credentials or sensitive configs are stored in the state.
    """
    target_path = Path(path)
    target_path.parent.mkdir(parents=True, exist_ok=True)
    temp_dir = target_path.parent

    # Strict hygiene: clean state ensuring no config objects, secrets, or raw URLs
    clean_state = sanitize_state(state)

    fd, tmp_file = tempfile.mkstemp(prefix="sched_state.", suffix=".tmp", dir=temp_dir, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(clean_state, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
        os.replace(tmp_file, target_path)
    except Exception:
        if os.path.exists(tmp_file):
            try:
                os.unlink(tmp_file)
            except Exception:
                pass
        raise


# Aliases for explicit module naming
load_scheduler_state = load_state
save_scheduler_state = save_state
