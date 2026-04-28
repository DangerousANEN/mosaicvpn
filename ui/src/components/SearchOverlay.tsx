/**
 * SearchOverlay — Ctrl+F / Ctrl+K command palette for the server
 * roster. Filters by name, host, city, country and protocol; Enter
 * connects to the highlighted row, Esc closes. Mirrors the Atlas
 * typography (paper card, copper accent on the active row) so it
 * reads as part of the app rather than a stock browser dropdown.
 */

import { useEffect, useMemo, useRef, useState } from "react";
import type { Server } from "../api/types";
import { locText } from "./locText";
import { getFavorites } from "../utils/localStore";

interface SearchOverlayProps {
  servers: Server[];
  onConnect: (id: string) => void;
  onClose: () => void;
}

export function SearchOverlay({
  servers,
  onConnect,
  onClose,
}: SearchOverlayProps): JSX.Element {
  const [q, setQ] = useState("");
  const [idx, setIdx] = useState(0);
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  const favorites = useMemo(() => getFavorites(), []);

  const results = useMemo(() => {
    const needle = q.trim().toLowerCase();
    const score = (s: Server): number => {
      // Empty query: order by favorites, then latency.
      if (needle === "") {
        let pri = 0;
        if (favorites.has(s.id)) pri -= 1000;
        const ms = s.last_test_ms ?? 0;
        if (ms > 0) pri += ms;
        else pri += 1_000_000;
        return pri;
      }
      const hay = [
        s.name,
        s.address,
        s.city ?? "",
        s.country ?? "",
        s.protocol,
        s.resolved_ip ?? "",
      ]
        .join(" ")
        .toLowerCase();
      if (!hay.includes(needle)) return Number.POSITIVE_INFINITY;
      // exact name / city / country match floats to top
      let s0 = 0;
      if (s.name.toLowerCase() === needle) s0 -= 100;
      if ((s.city ?? "").toLowerCase() === needle) s0 -= 80;
      if ((s.country ?? "").toLowerCase() === needle) s0 -= 80;
      if (favorites.has(s.id)) s0 -= 40;
      // Earlier match positions score better
      s0 += hay.indexOf(needle);
      const ms = s.last_test_ms ?? 0;
      if (ms > 0) s0 += ms / 100;
      return s0;
    };
    return [...servers]
      .map((s) => ({ s, k: score(s) }))
      .filter((p) => Number.isFinite(p.k))
      .sort((a, b) => a.k - b.k)
      .slice(0, 25)
      .map((p) => p.s);
  }, [servers, q, favorites]);

  useEffect(() => {
    setIdx((i) => (i >= results.length ? 0 : i));
  }, [results.length]);

  const onKey = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setIdx((i) => Math.min(results.length - 1, i + 1));
      return;
    }
    if (e.key === "ArrowUp") {
      e.preventDefault();
      setIdx((i) => Math.max(0, i - 1));
      return;
    }
    if (e.key === "Enter") {
      e.preventDefault();
      const target = results[idx];
      if (target) {
        onConnect(target.id);
        onClose();
      }
      return;
    }
    if (e.key === "Escape") {
      e.preventDefault();
      onClose();
    }
  };

  return (
    <div className="search-overlay-scrim" onClick={onClose}>
      <div className="search-overlay" onClick={(e) => e.stopPropagation()}>
        <div className="search-overlay-eyebrow mono">
          Quick connect — <span className="italic-mute">type to filter, ↑↓ to navigate, Enter to connect, Esc to close</span>
        </div>
        <input
          ref={inputRef}
          type="text"
          className="search-overlay-input"
          placeholder="Filter by name / host / city / country…"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={onKey}
          autoComplete="off"
          spellCheck={false}
        />
        <div className="search-overlay-list">
          {results.length === 0 ? (
            <div className="search-overlay-empty italic-mute">
              No matching stations.
            </div>
          ) : null}
          {results.map((s, i) => {
            const ms = s.last_test_ms;
            const dead = (ms ?? 0) < 0;
            const live = (ms ?? 0) > 0 && !s.last_test_error;
            return (
              <div
                key={s.id}
                className={`search-overlay-row ${i === idx ? "cur" : ""}`}
                onMouseEnter={() => setIdx(i)}
                onClick={() => {
                  onConnect(s.id);
                  onClose();
                }}
              >
                <div className="row-name">
                  {favorites.has(s.id) ? (
                    <span className="fav-dot" aria-hidden="true">
                      ★
                    </span>
                  ) : null}
                  {s.name}
                </div>
                <div className="row-meta mono">
                  {s.protocol.toUpperCase()}
                  {locText(s) ? ` · ${locText(s)}` : ""}
                </div>
                <div className="row-ms mono">
                  {dead ? "fail" : live ? `${ms}ms` : "—"}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
