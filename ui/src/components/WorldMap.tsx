/**
 * WorldMap renders the world outline (flekschas/simple-world-map,
 * MIT, mirrored under ui/src/assets/world.svg) plus a graticule and
 * per-host pins. The map's native viewBox is
 * `30.767 241.591 784.077 458.627` and its projection is approximately
 * — but not exactly — equirectangular. We fit the projection
 * empirically against ~6 country centroids (see project()), which
 * lines up Brazil, Egypt, India, Iceland, Madagascar and South Africa
 * to within a few pixels of their actual mainland.
 *
 * Both the world image and the pin layer share that viewBox and use
 * `preserveAspectRatio="none"` so they stretch identically across the
 * container — ditto for the graticule. Stretching breaks geographic
 * accuracy slightly when the container aspect drifts from 1.71:1, but
 * keeps every pin glued to its country.
 *
 * Pins are *host* pins — multiple servers sharing the same resolved
 * IP (or the same lat/lon to ~0.5°) collapse into a single teardrop
 * marker so a datacenter exposing three protocols doesn't draw three
 * overlapping pins. Hovering reveals a tooltip with the host,
 * location and member protocols. Clicking a single-host pin connects
 * directly; clicking a multi-host pin opens a popover with one
 * Connect button per member protocol so the user picks the variant
 * they want.
 */

import { useState, type MouseEvent as ReactMouseEvent } from "react";
import { TransformWrapper, TransformComponent } from "react-zoom-pan-pinch";
import worldUrl from "../assets/world.svg";
import type { Server, GeoLocation } from "../api/types";
import { cityToLatLon } from "./cityCoords";
import { groupServers, type ServerGroup } from "./serverGroup";
import {
  clusterByCountry,
  type CountryCluster,
  type WorldPin,
} from "./countryCluster";
import { locText } from "./locText";

interface WorldMapProps {
  servers: Server[];
  activeServerId?: string;
  /** Optional caption shown in the top-right corner (e.g. current bearing). */
  bearing?: string;
  /** Connect handler invoked with the chosen server id. Single-host
   *  pins call this directly on click; multi-host pins call it from
   *  the popover. Omit to render non-clickable pins (hover still
   *  works). */
  onPinClick?: (serverId: string) => void;
  /** User's resolved IP-geo location (from /v1/status). When
   *  provided, drives the position of the "vous" pin instead of
   *  the (lon=0, lat=20°N) fallback. */
  myLocation?: GeoLocation;
}

interface HostPinPos {
  kind: "host";
  x: number;
  y: number;
  group: ServerGroup;
  active: boolean;
  primaryMs?: number;
}

interface CountryPinPos {
  kind: "country";
  x: number;
  y: number;
  cluster: CountryCluster;
  active: boolean;
  primaryMs?: number;
}

type PinPos = HostPinPos | CountryPinPos;

// world.svg's native viewBox. Both the world image and the pin layer
// use it so coordinates are directly comparable.
const MAP_VB = { x: 30.767, y: 241.591, w: 784.077, h: 458.627 } as const;

// Empirical fit of the simple-world-map projection: linear in lon/lat
// with constants regressed against the bbox centroids of 6 country
// paths in the source SVG (br, eg, in, is, mg, za). Residuals stay
// under ~10 px on a 784×459 canvas, well under one pin diameter.
const LON_OFFSET = 409.7;
const LON_SCALE = 2.414;
const LAT_OFFSET = 530.8;
const LAT_SCALE = 2.787;

function project(lat: number, lon: number): { x: number; y: number } {
  return {
    x: LON_OFFSET + LON_SCALE * lon,
    y: LAT_OFFSET - LAT_SCALE * lat,
  };
}

// Fallback "vous" anchor used until mosaicd's IP-geo lookup
// resolves Status.MyLocation. Sits roughly where Earth's median
// land mass lives — lon=0, lat=20°N. Replaced live by
// myLocation prop once the daemon publishes a real coordinate.
const YOU_FALLBACK = project(20, 0);

/**
 * Pins within MERGE_RADIUS viewBox-units of each other collapse into
 * one teardrop. With LON_SCALE=2.414 px/° this is roughly ~5° of
 * longitude — the user explicitly asked for more aggressive merging
 * than rc12's ~0.5° so adjacent datacenters in the same metro lump
 * into a single marker and the map stays legible. Members of merged
 * groups are concatenated and the merged group inherits the better
 * latency.
 */
const MERGE_RADIUS = 12;

function mergeNearbyHostPins(pins: HostPinPos[]): HostPinPos[] {
  if (pins.length < 2) return pins;
  const out: HostPinPos[] = [];
  for (const p of pins) {
    const near = out.find(
      (o) =>
        Math.abs(o.x - p.x) < MERGE_RADIUS &&
        Math.abs(o.y - p.y) < MERGE_RADIUS,
    );
    if (!near) {
      out.push({ ...p, group: { ...p.group, members: [...p.group.members] } });
      continue;
    }
    near.group.members.push(...p.group.members);
    if (p.active) near.active = true;
    if (
      p.primaryMs !== undefined &&
      (near.primaryMs === undefined || p.primaryMs < near.primaryMs)
    ) {
      near.primaryMs = p.primaryMs;
      near.group.primary = p.group.primary;
    }
  }
  return out;
}

/** Centroid-based label for a country pin. ISO + count + best ms. */
function countryLabel(c: CountryCluster): string {
  const ms = c.bestMs !== null && c.bestMs > 0 ? ` · ${c.bestMs}ms` : "";
  return `${c.iso} · ${c.totalServers}${ms}`;
}

/** Pin's primary city (or host) label, used for host pins. */
function hostLabel(p: HostPinPos): string {
  const ms = p.primaryMs !== undefined ? ` · ${p.primaryMs}` : "";
  const city = p.group.primary.city || p.group.host;
  return `${city}${ms}`;
}

function pinForGroup(g: ServerGroup, activeServerId?: string): HostPinPos | null {
  // Try the primary member first, then any member with coordinates.
  for (const srv of [g.primary, ...g.members]) {
    let lat: number | undefined;
    let lon: number | undefined;
    if (
      typeof srv.lat === "number" &&
      typeof srv.lon === "number" &&
      (srv.lat !== 0 || srv.lon !== 0)
    ) {
      lat = srv.lat;
      lon = srv.lon;
    } else {
      const coords = cityToLatLon(srv.city, srv.country, srv.address);
      if (coords) {
        lat = coords.lat;
        lon = coords.lon;
      }
    }
    if (lat === undefined || lon === undefined) continue;
    const { x, y } = project(lat, lon);
    return {
      kind: "host",
      x,
      y,
      group: g,
      active: g.members.some((m) => m.id === activeServerId),
      primaryMs:
        g.bestMs !== null && g.bestMs > 0 ? g.bestMs : undefined,
    };
  }
  return null;
}

function pinForCluster(
  c: CountryCluster,
  activeServerId?: string,
): CountryPinPos {
  const { x, y } = project(c.lat, c.lon);
  const active = c.members.some((g) =>
    g.members.some((m) => m.id === activeServerId),
  );
  return {
    kind: "country",
    x,
    y,
    cluster: c,
    active,
    primaryMs: c.bestMs !== null && c.bestMs > 0 ? c.bestMs : undefined,
  };
}

export function WorldMap({
  servers,
  activeServerId,
  bearing,
  onPinClick,
  myLocation,
}: WorldMapProps): JSX.Element {
  const [hoverIdx, setHoverIdx] = useState<number | null>(null);
  const [openIdx, setOpenIdx] = useState<number | null>(null);
  const [vousOpen, setVousOpen] = useState(false);
  // Live "vous" anchor: real public-IP geolocation if the daemon
  // resolved one, else the fallback off the West African coast.
  const YOU = myLocation
    ? project(myLocation.lat, myLocation.lon)
    : YOU_FALLBACK;
  // The current zoom level reported by react-zoom-pan-pinch. Drives
  // (a) inverse-scale on every pin so a 12× zoom doesn't blow the
  // diamonds up to half the screen, and (b) the country/host pin
  // toggle below.
  const [scale, setScale] = useState(1);
  const groups = groupServers(servers);
  // Cluster countries first (a 1 000-server pool collapses from
  // hundreds of teardrops to ~30 country pins); pass through host
  // pins for low-population countries.
  const worldPins: WorldPin[] = clusterByCountry(groups);
  const rawHosts: HostPinPos[] = [];
  const countryPins: CountryPinPos[] = [];
  for (const wp of worldPins) {
    if (wp.kind === "host") {
      const p = pinForGroup(wp.group, activeServerId);
      if (p) rawHosts.push(p);
    } else {
      countryPins.push(pinForCluster(wp, activeServerId));
    }
  }
  // Below ~1.8× zoom we hide the per-host diamonds entirely so a
  // 1 000-server feed reads as ~30 country pins instead of "каша";
  // host diamonds reappear automatically once the user zooms past
  // that threshold (or just clicks a country to drill into it).
  const hostPins = scale >= 1.8 ? mergeNearbyHostPins(rawHosts) : [];
  // Order: country pins first (drawn behind), host pins on top so an
  // individually labelled city remains clickable when it overlaps a
  // country centroid.
  const pins: PinPos[] = [...countryPins, ...hostPins];
  // Inverse zoom for SVG/HTML markers — keeps pins a constant
  // on-screen size as the user zooms in. Floor at 0.4 so the
  // 12× max zoom still shows readable diamonds.
  const pinScale = Math.max(0.4, 1 / scale);
  const activePin = pins.find((p) => p.active);
  // Suppress the hover tooltip whenever a popover is open — they live
  // in the same on-screen real estate and would otherwise overlap.
  const hover = openIdx === null && hoverIdx !== null ? pins[hoverIdx] : null;
  const open = openIdx !== null ? pins[openIdx] ?? null : null;

  // Graticule lines in the same map coordinates: equator, tropics &
  // arctic/antarctic circles for horizontals; longitude steps every
  // 30° for verticals. We clip to the visible viewBox so high-latitude
  // verticals don't paint outside the world outline.
  const clipL = MAP_VB.x;
  const clipR = MAP_VB.x + MAP_VB.w;
  const clipT = MAP_VB.y;
  const clipB = MAP_VB.y + MAP_VB.h;
  const horizontals = [-66.5, -45, -23.5, 23.5, 45, 66.5]
    .map((lat) => project(lat, 0).y)
    .filter((y) => y > clipT && y < clipB);
  const equatorY = project(0, 0).y;
  const verticals = [-150, -120, -90, -60, -30, 30, 60, 90, 120, 150]
    .map((lon) => project(0, lon).x)
    .filter((x) => x > clipL && x < clipR);
  const meridianX = project(0, 0).x;

  return (
    <div className="worldmap">
      {/* The aspect-locked stage. Holds the world image, graticule,
          pin overlay, tooltip and popover. Centered inside the parent
          .map pane so the world never gets stretched horizontally —
          letterboxing instead when the parent isn't 1.71:1. */}
      <div className="worldmap-stage">
      {/* Pan + pinch wrapper. minScale=1 keeps the world fitted as the
          neutral state; users can zoom in up to 6x for dense regions
          and pan with click-drag. doubleClick.mode="reset" gives a
          quick way back to fit-view. limitToBounds keeps panning
          inside the visible stage. */}
      <TransformWrapper
        minScale={1}
        maxScale={12}
        doubleClick={{ mode: "reset" }}
        limitToBounds={true}
        centerOnInit={true}
        // rc25 set step=0.05 but the user reported the wheel
        // gesture felt identical to the rc24 0.15 step. Reason:
        // react-zoom-pan-pinch picks `smoothStep` for the per-event
        // delta when smooth-scroll is active (default), and that
        // value defaulted to 0.001 × raw deltaY — dwarfing the
        // `step` value on a high-DPI mouse. We lower BOTH so a
        // single notch on the user's MX-style wheel produces a
        // ~3 % zoom change instead of jumping straight from 1× to
        // 5×. With the new maxScale=12 there's enough headroom
        // for the planned hierarchical drill-down (continent →
        // country → city → server) to feel like a real map.
        wheel={{ step: 0.03 }}
        pinch={{ step: 5 }}
        panning={{ velocityDisabled: true }}
        onTransform={(_ref: unknown, state: { scale: number }) => {
          // Track the current scale so pin sizes can be inverted
          // (constant on-screen size regardless of zoom) and so we
          // can swap country pins out for individual host pins as
          // the user zooms in past ~2×.
          setScale(state.scale);
        }}
      >
        <TransformComponent
          wrapperStyle={{
            width: "100%",
            height: "100%",
            // Same beige tone as the map's land fill so when the
            // user pans toward an edge the gap between map and
            // the stage's clipped frame doesn't reveal a different
            // background colour (the rc24 "ugly borders" report).
            background: "var(--worldmap-bg, #d8c8a8)",
            overflow: "hidden",
          }}
          contentStyle={{
            width: "100%",
            height: "100%",
            position: "relative",
          }}
        >
      <svg
        className="worldmap-img"
        viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
        preserveAspectRatio="none"
        aria-hidden="true"
      >
        <image
          href={worldUrl}
          x={MAP_VB.x}
          y={MAP_VB.y}
          width={MAP_VB.w}
          height={MAP_VB.h}
          preserveAspectRatio="none"
        />
      </svg>
      <svg
        className="worldmap-grat"
        viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
        preserveAspectRatio="none"
      >
        <line className="eq" x1={clipL} y1={equatorY} x2={clipR} y2={equatorY} />
        <line className="eq" x1={meridianX} y1={clipT} x2={meridianX} y2={clipB} />
        {horizontals.map((y) => (
          <line key={`h${y.toFixed(1)}`} x1={clipL} y1={y} x2={clipR} y2={y} />
        ))}
        {verticals.map((x) => (
          <line key={`v${x.toFixed(1)}`} x1={x} y1={clipT} x2={x} y2={clipB} />
        ))}
      </svg>

      {pins.length > 0 ? (
        <svg
          className="worldmap-pins"
          viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
          preserveAspectRatio="none"
        >
          {/* Idle connection lines: thin dashed paper-tone curves
              from "you" to every non-active pin. Drawn first so the
              copper arc to the active pin paints on top. */}
          {pins.map((p, i) => {
            if (p.active) return null;
            const mx = (YOU.x + p.x) / 2;
            const my = Math.min(YOU.y, p.y) - 28;
            const key = p.kind === "host" ? p.group.key : `cc-${p.cluster.iso}`;
            return (
              <path
                key={`link-${key}-${i}`}
                className="worldmap-link"
                d={`M ${YOU.x} ${YOU.y} Q ${mx} ${my} ${p.x} ${p.y}`}
              />
            );
          })}
          {activePin ? (
            <path
              className="worldmap-arc"
              d={`M ${YOU.x} ${YOU.y} Q ${(YOU.x + activePin.x) / 2} ${
                Math.min(YOU.y, activePin.y) - 60
              } ${activePin.x} ${activePin.y}`}
            />
          ) : null}
          {pins.map((p, i) => {
            const isOpen = openIdx === i;
            const isHov = i === hoverIdx;
            const isCountry = p.kind === "country";
            const cls = `worldmap-pin ${p.active ? "cur" : ""} ${
              isHov ? "hov" : ""
            } ${isOpen ? "open" : ""} ${onPinClick ? "clickable" : ""} ${
              isCountry ? "is-country" : ""
            }`;
            const multi = p.kind === "host"
              ? p.group.members.length > 1
              : true;
            const key =
              p.kind === "host" ? p.group.key : `cc-${p.cluster.iso}`;
            const onPinClickHandler = (e: ReactMouseEvent) => {
              if (!onPinClick) return;
              e.stopPropagation();
              if (multi) {
                setOpenIdx((o) => (o === i ? null : i));
              } else if (p.kind === "host") {
                setOpenIdx(null);
                onPinClick(p.group.primary.id);
              }
            };
            return (
              <g
                key={key}
                className={cls}
                transform={`translate(${p.x},${p.y}) scale(${pinScale})`}
              >
                {/* Idle: thin dashed stem + diamond outline.
                    Active: same diamond filled with the copper
                    accent so the user can tell at a glance which
                    server the tunnel is currently routed through —
                    the rc25 teardrop made the active marker look
                    like a different category of object than the
                    idle ones, which the user explicitly disliked.
                    Hover stays grey (CSS handles the colour swap
                    via .worldmap-pin.hov), so the three states are
                    visually distinguishable: idle = paper, hover =
                    grey, active = orange. */}
                <line
                  x1={0}
                  y1={0}
                  x2={0}
                  y2={-6}
                  className="pin-stem"
                />
                <path
                  className="pin-diamond"
                  d="M 0 -26 L 10 -16 L 0 -6 L -10 -16 Z"
                />
                {/* Multi-host marker: small dot inside the diamond. */}
                {multi ? (
                  <circle
                    cy={-16}
                    r={2.2}
                    className="pin-multi-dot"
                  />
                ) : null}
                {/* Invisible hit target — bigger than the visible mark
                    so hover + click stay easy on small renderings. */}
                <circle
                  cy={-16}
                  r={20}
                  fill="transparent"
                  style={onPinClick ? { cursor: "pointer" } : undefined}
                  onMouseEnter={() => setHoverIdx(i)}
                  onMouseLeave={() =>
                    setHoverIdx((h) => (h === i ? null : h))
                  }
                  onClick={onPinClickHandler}
                />
              </g>
            );
          })}
          {/* "vous" indicator — small ink dot, italic label is rendered
              as an HTML overlay below so it picks up the app font. */}
          <g
            className="worldmap-pin you"
            transform={`translate(${YOU.x},${YOU.y})`}
          >
            <circle r={2.5} className="dot" />
          </g>
        </svg>
      ) : null}

      {/* Per-pin label boxes — "City · ms" for host pins, "<ISO> · N
          servers" for country clusters. Rendered as HTML so the
          label uses the same serif as the rest of the marginalia and
          stays crisp regardless of how the SVG is scaled. The active
          pin's label gets the copper fill from the reference design. */}
      {pins.map((p, i) => {
        const label =
          p.kind === "host" ? hostLabel(p) : countryLabel(p.cluster);
        const key =
          p.kind === "host" ? `lab-${p.group.key}-${i}` : `lab-cc-${p.cluster.iso}-${i}`;
        const cls = `worldmap-label ${p.active ? "cur" : ""} ${
          onPinClick ? "clickable" : ""
        } ${p.kind === "country" ? "is-country" : ""}`;
        const onLabelClick = (e: ReactMouseEvent) => {
          if (!onPinClick) return;
          e.stopPropagation();
          if (p.kind === "country") {
            setOpenIdx((o) => (o === i ? null : i));
            return;
          }
          if (p.group.members.length > 1) {
            setOpenIdx((o) => (o === i ? null : i));
          } else {
            setOpenIdx(null);
            onPinClick(p.group.primary.id);
          }
        };
        return (
          <div
            key={key}
            className={cls}
            style={{
              left: `${((p.x - MAP_VB.x) / MAP_VB.w) * 100}%`,
              top: `${((p.y - MAP_VB.y) / MAP_VB.h) * 100}%`,
              // Inverse-scale so labels stay a constant on-screen
              // size as the user zooms in (rc26 only inverse-
              // scaled the SVG diamonds, leaving HTML labels to
              // grow comically large past 4x). Keeps the
              // existing "below the pin" offset baseline (rc23).
              transform: `translate(-50%, 12px) scale(${pinScale})`,
              transformOrigin: "center top",
            }}
            onMouseEnter={() => setHoverIdx(i)}
            onMouseLeave={() =>
              setHoverIdx((h) => (h === i ? null : h))
            }
            onClick={onLabelClick}
          >
            {label}
          </div>
        );
      })}

      {/* "vous" label, italic + ink, anchored to YOU. Clickable
          since rc27: opens a small popover identifying the marker
          as the user's IP-geo location. */}
      <div
        className="worldmap-you-label clickable"
        style={{
          left: `${((YOU.x - MAP_VB.x) / MAP_VB.w) * 100}%`,
          top: `${((YOU.y - MAP_VB.y) / MAP_VB.h) * 100}%`,
        }}
        onClick={(e) => {
          e.stopPropagation();
          setVousOpen((v) => !v);
        }}
      >
        vous
      </div>

      {vousOpen ? (
        <div
          className="worldmap-tooltip vous-tip"
          style={{
            left: `${((YOU.x - MAP_VB.x) / MAP_VB.w) * 100}%`,
            top: `${((YOU.y - MAP_VB.y) / MAP_VB.h) * 100}%`,
          }}
          onClick={(e) => e.stopPropagation()}
        >
          <div className="tip-host">It’s your location.</div>
          {myLocation ? (
            <>
              {(myLocation.city || myLocation.country) ? (
                <div className="tip-loc">
                  {[myLocation.city, myLocation.country]
                    .filter(Boolean)
                    .join(", ")}
                </div>
              ) : null}
              <div className="tip-ms mono">
                {myLocation.lat.toFixed(2)},{" "}
                {myLocation.lon.toFixed(2)}
              </div>
            </>
          ) : (
            <div className="tip-loc italic-mute">
              resolving via ip-api…
            </div>
          )}
        </div>
      ) : null}

      {hover ? (
        <div
          className="worldmap-tooltip"
          style={{
            left: `${((hover.x - MAP_VB.x) / MAP_VB.w) * 100}%`,
            top: `${((hover.y - MAP_VB.y) / MAP_VB.h) * 100}%`,
          }}
        >
          {hover.kind === "host" ? (
            <>
              <div className="tip-host mono">{hover.group.host}</div>
              {locText(hover.group.primary) ? (
                <div className="tip-loc">{locText(hover.group.primary)}</div>
              ) : null}
              <div className="tip-protos mono">
                {hover.group.members
                  .map((m) => `${m.protocol}:${m.port}`)
                  .join(" · ")}
              </div>
              {hover.primaryMs !== undefined ? (
                <div className="tip-ms mono">best {hover.primaryMs}ms</div>
              ) : null}
              {onPinClick ? (
                <div className="tip-cta mono">
                  {hover.group.members.length > 1
                    ? "click to choose"
                    : "click to connect"}
                </div>
              ) : null}
            </>
          ) : (
            <>
              <div className="tip-host mono">{hover.cluster.iso}</div>
              <div className="tip-loc">
                {hover.cluster.members.length} cities ·{" "}
                {hover.cluster.totalServers} servers
              </div>
              {hover.primaryMs !== undefined ? (
                <div className="tip-ms mono">best {hover.primaryMs}ms</div>
              ) : null}
              {onPinClick ? (
                <div className="tip-cta mono">click to choose</div>
              ) : null}
            </>
          )}
        </div>
      ) : null}

      {open ? (
        <>
          <div
            className="worldmap-popover-scrim"
            onClick={() => setOpenIdx(null)}
          />
          <div
            className="worldmap-popover"
            style={{
              left: `${((open.x - MAP_VB.x) / MAP_VB.w) * 100}%`,
              top: `${((open.y - MAP_VB.y) / MAP_VB.h) * 100}%`,
            }}
          >
            {open.kind === "host" ? (
              <>
                <div className="pop-head">
                  <div className="pop-host mono">{open.group.host}</div>
                  {locText(open.group.primary) ? (
                    <div className="pop-loc">{locText(open.group.primary)}</div>
                  ) : null}
                </div>
                <ul className="pop-list">
                  {open.group.members.map((m) => {
                    const ms =
                      m.last_test_ms !== undefined && m.last_test_ms > 0
                        ? `${m.last_test_ms}ms`
                        : m.last_test_error
                          ? "err"
                          : "—";
                    const isActive = m.id === activeServerId;
                    return (
                      <li key={m.id} className={isActive ? "is-active" : ""}>
                        <span className="pop-proto mono">
                          {m.protocol}:{m.port}
                        </span>
                        <span className="pop-ms mono">{ms}</span>
                        <button
                          type="button"
                          className="pop-go mono"
                          disabled={!onPinClick || isActive}
                          onClick={(e) => {
                            e.stopPropagation();
                            if (!onPinClick) return;
                            setOpenIdx(null);
                            onPinClick(m.id);
                          }}
                        >
                          {isActive ? "current" : "connect"}
                        </button>
                      </li>
                    );
                  })}
                </ul>
              </>
            ) : (
              <>
                <div className="pop-head">
                  <div className="pop-host mono">
                    {open.cluster.iso} · {open.cluster.members.length} cities
                  </div>
                  <div className="pop-loc">
                    {open.cluster.totalServers} servers
                  </div>
                </div>
                <ul className="pop-list">
                  {open.cluster.members.slice(0, 12).map((g) => {
                    const best = g.bestMs;
                    const ms =
                      best !== null && best > 0 ? `${best}ms` : "—";
                    const city = g.primary.city || g.host;
                    const isActive = g.members.some(
                      (m) => m.id === activeServerId,
                    );
                    return (
                      <li key={g.key} className={isActive ? "is-active" : ""}>
                        <span className="pop-proto mono">{city}</span>
                        <span className="pop-ms mono">{ms}</span>
                        <button
                          type="button"
                          className="pop-go mono"
                          disabled={!onPinClick || isActive}
                          onClick={(e) => {
                            e.stopPropagation();
                            if (!onPinClick) return;
                            setOpenIdx(null);
                            onPinClick(g.primary.id);
                          }}
                        >
                          {isActive ? "current" : "connect"}
                        </button>
                      </li>
                    );
                  })}
                  {open.cluster.members.length > 12 ? (
                    <li className="pop-more">
                      + {open.cluster.members.length - 12} more cities
                    </li>
                  ) : null}
                </ul>
              </>
            )}
          </div>
        </>
      ) : null}

      {bearing ? <div className="worldmap-bearing">{bearing}</div> : null}
        </TransformComponent>
      </TransformWrapper>
      </div>
    </div>
  );
}
