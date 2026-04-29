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
 * rc30 — zoom-level clustering. The rc28 pixel-distance merge is
 * replaced by a discrete continent → country → city → server
 * hierarchy keyed off `levelForScale(scale)` (see ./levelCluster.ts).
 * A cluster whose bucket ended up with exactly one server group
 * collapses to a diamond pin so a country with one server skips the
 * "circle-with-1" badge. Clicking a multi-member cluster zooms the
 * TransformWrapper to the cluster's projected bbox + 20% padding; the
 * next re-cluster falls out of the scale-dependent useMemo one level
 * deeper.
 *
 * rc30 — city reference overlay. A bundled top-1000-by-population
 * cities set (./data/cities-top1000.json) is drawn as 9 px serif
 * labels plus pepper-dot anchors once `scale ≥ 3` (city level), so the
 * map reads as an atlas when you zoom in on a region, not just a
 * pin plot. Cities are filtered to the current viewport and capped at
 * ~220 labels per frame to keep the render cheap.
 *
 * rc30 — server labels hidden by default. Individual server labels
 * stay hidden at city/country/continent zooms unless the user hovers
 * the pin; once `scale ≥ 6` (server level) they always show.
 *
 * rc30 — floating update banner. The update banner is now a fixed
 * pill (bottom-right) instead of a topbar strip — see
 * `./UpdateBanner.tsx` + `.update-banner` in `../styles/app.css`.
 *
 * rc30 — vous pin counter-scale. The "vous" marker and its italic
 * label now counter-scale with zoom like every other pin, so the
 * user's own pin doesn't grow to cover half the map at max zoom.
 */

import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type MouseEvent as ReactMouseEvent,
} from "react";
import {
  TransformComponent,
  TransformWrapper,
  type ReactZoomPanPinchRef,
} from "react-zoom-pan-pinch";
import worldUrl from "../assets/world.svg";
import type { Server, GeoLocation } from "../api/types";
import { locText } from "./locText";
import {
  clusterAtLevel,
  levelForScale,
  projectVB,
  resolveGroups,
  type LevelCluster,
} from "./levelCluster";
import citiesData from "../data/cities-top1000.json";

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
  /** When set, only servers belonging to the subscription with this
   *  ID are rendered. Drives the rc28 filter chips above the map. */
  subscriptionFilter?: string | null;
}

interface CityDatum {
  name: string;
  lat: number;
  lng: number;
  country: string;
  pop: number;
}

// world.svg's native viewBox. Both the world image and the pin layer
// use it so coordinates are directly comparable.
const MAP_VB = { x: 30.767, y: 241.591, w: 784.077, h: 458.627 } as const;

// Empirical fit of the simple-world-map projection: linear in lon/lat
// with constants regressed against the bbox centroids of 6 country
// paths in the source SVG (br, eg, in, is, mg, za). Residuals stay
// under ~10 px on a 784×459 canvas, well under one pin diameter.
function project(lat: number, lon: number): { x: number; y: number } {
  return projectVB(lat, lon);
}

// Fallback "vous" anchor used until mosaicd's IP-geo lookup
// resolves Status.MyLocation. Sits roughly where Earth's median
// land mass lives — lon=0, lat=20°N. Replaced live by
// myLocation prop once the daemon publishes a real coordinate.
const YOU_FALLBACK = project(20, 0);

// Project every city once and sort by population descending so the
// viewport filter keeps the biggest cities first.
const CITIES: Array<CityDatum & { vbX: number; vbY: number }> = (
  citiesData as CityDatum[]
)
  .map((c) => {
    const p = projectVB(c.lat, c.lng);
    return { ...c, vbX: p.x, vbY: p.y };
  })
  .sort((a, b) => b.pop - a.pop);

/** Cluster label suffix — appends best-ms when a member has been
 *  probed. Kept out of the JSX so it's testable in isolation. */
function msSuffix(c: LevelCluster): string {
  return c.bestMs !== null && c.bestMs > 0 ? ` · ${c.bestMs}ms` : "";
}

function clusterLabel(c: LevelCluster): string {
  if (c.members.length === 1 && c.level === "server") {
    const g = c.members[0].group;
    const city = g.primary.city || g.host;
    return `${city}${msSuffix(c)}`;
  }
  if (c.members.length === 1) {
    // Single group at a higher level: label with the group's city
    // but don't falsely advertise it as a cluster.
    const g = c.members[0].group;
    const city = g.primary.city || g.host;
    return `${city}${msSuffix(c)}`;
  }
  return `${c.label} · ${c.totalServers}${msSuffix(c)}`;
}

export function WorldMap({
  servers,
  activeServerId,
  bearing,
  onPinClick,
  myLocation,
  subscriptionFilter,
}: WorldMapProps): JSX.Element {
  const [hoverIdx, setHoverIdx] = useState<number | null>(null);
  const [openIdx, setOpenIdx] = useState<number | null>(null);
  const [vousOpen, setVousOpen] = useState(false);
  const [scale, setScale] = useState(1);
  const [stageSize, setStageSize] = useState({ w: 800, h: 460 });
  const stageRef = useRef<HTMLDivElement | null>(null);
  const transformRef = useRef<ReactZoomPanPinchRef | null>(null);

  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      for (const e of entries) {
        setStageSize({ w: e.contentRect.width, h: e.contentRect.height });
      }
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Live "vous" anchor: real public-IP geolocation if the daemon
  // resolved one, else the fallback off the West African coast.
  const YOU = myLocation
    ? project(myLocation.lat, myLocation.lon)
    : YOU_FALLBACK;

  const filtered = useMemo(() => {
    if (!subscriptionFilter) return servers;
    return servers.filter((s) => s.subscription_id === subscriptionFilter);
  }, [servers, subscriptionFilter]);

  // Resolve groups once per server set; cluster once per zoom level.
  const { resolved, activeKey } = useMemo(
    () => resolveGroups(filtered, activeServerId),
    [filtered, activeServerId],
  );

  const level = levelForScale(scale);

  const clusters = useMemo(
    () => clusterAtLevel(resolved, level, activeKey),
    [resolved, level, activeKey],
  );

  // Inverse zoom for SVG/HTML markers — keeps pins a constant
  // on-screen size as the user zooms in. Floor at 0.4 so the
  // 12× max zoom still shows readable diamonds.
  const pinScale = Math.max(0.4, 1 / scale);
  const activePin = clusters.find((c) => c.active);
  const hover = openIdx === null && hoverIdx !== null ? clusters[hoverIdx] : null;
  const open = openIdx !== null ? clusters[openIdx] ?? null : null;

  // City overlay comes alive once we're past continent zoom. Filter
  // to the currently visible viewport (approximated via the wrapper
  // scale — we can't read the pan offset from here without a ref
  // stash, and the cap is per-frame anyway) and cap at 220 labels
  // so the renderer stays under a few ms per frame.
  const cityOverlay = useMemo(() => {
    if (scale < 3) return [];
    const cap = scale < 4 ? 140 : scale < 6 ? 220 : 400;
    return CITIES.slice(0, cap);
  }, [scale]);

  // Drill-down: zoom-to-fit a cluster's bbox in viewBox units. We
  // convert the bbox → fraction of the total viewBox, derive the
  // target scale that fits it with 20% padding, then translate the
  // wrapper so the cluster centroid lands in the middle of the stage.
  const drillToCluster = (c: LevelCluster) => {
    const wrapper = transformRef.current;
    if (!wrapper) return;
    const w = Math.max(1, c.bbox.maxX - c.bbox.minX);
    const h = Math.max(1, c.bbox.maxY - c.bbox.minY);
    // Minimum footprint so a tight cluster still produces a useful
    // zoom step (otherwise a dense metro-area cluster would snap
    // straight to maxScale=12).
    const minSpan = 40; // viewBox units
    const eW = Math.max(w, minSpan);
    const eH = Math.max(h, minSpan);
    const fracW = eW / MAP_VB.w;
    const fracH = eH / MAP_VB.h;
    // 0.7 keeps ~30% padding around the cluster once it's centred.
    const fitScale = 0.7 / Math.max(fracW, fracH, 0.0001);
    const targetScale = Math.min(12, Math.max(scale + 0.5, fitScale));
    // Centre the cluster centroid in the stage.
    const cx = (c.vbX - MAP_VB.x) / MAP_VB.w;
    const cy = (c.vbY - MAP_VB.y) / MAP_VB.h;
    const tx = stageSize.w / 2 - cx * stageSize.w * targetScale;
    const ty = stageSize.h / 2 - cy * stageSize.h * targetScale;
    wrapper.setTransform(tx, ty, targetScale, 600, "easeOut");
  };

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
      <div className="worldmap-stage" ref={stageRef}>
      <TransformWrapper
        ref={transformRef}
        minScale={1}
        maxScale={12}
        doubleClick={{ mode: "reset" }}
        limitToBounds={true}
        centerOnInit={true}
        wheel={{ step: 0.03 }}
        pinch={{ step: 5 }}
        panning={{ velocityDisabled: true }}
        onTransform={(_ref: unknown, state: { scale: number }) => {
          setScale(state.scale);
        }}
      >
        <TransformComponent
          wrapperStyle={{
            width: "100%",
            height: "100%",
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
        preserveAspectRatio="xMidYMid meet"
        aria-hidden="true"
      >
        <image
          href={worldUrl}
          x={MAP_VB.x}
          y={MAP_VB.y}
          width={MAP_VB.w}
          height={MAP_VB.h}
          preserveAspectRatio="xMidYMid meet"
        />
      </svg>
      <svg
        className="worldmap-grat"
        viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
        preserveAspectRatio="xMidYMid meet"
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

      {/* City reference overlay. Rendered underneath the pin layer so
          pin strokes paint on top. Dots are 0.9 px in viewBox units
          and counter-scaled via non-scaling-stroke; labels are HTML
          so we get real 9px serif text without SVG text sizing drift. */}
      {cityOverlay.length > 0 ? (
        <svg
          className="worldmap-cities"
          viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
          preserveAspectRatio="xMidYMid meet"
        >
          {cityOverlay.map((c) => (
            <circle
              key={`cd-${c.country}-${c.name}`}
              cx={c.vbX}
              cy={c.vbY}
              r={0.9 / scale}
              className="city-dot"
            />
          ))}
        </svg>
      ) : null}
      {cityOverlay.length > 0
        ? cityOverlay.map((c) => (
            <div
              key={`cl-${c.country}-${c.name}`}
              className="worldmap-city-label"
              style={{
                left: `${((c.vbX - MAP_VB.x) / MAP_VB.w) * 100}%`,
                top: `${((c.vbY - MAP_VB.y) / MAP_VB.h) * 100}%`,
                transform: `translate(4px, -50%) scale(${pinScale})`,
                transformOrigin: "left center",
              }}
            >
              {c.name}
            </div>
          ))
        : null}

      {clusters.length > 0 ? (
        <svg
          className="worldmap-pins"
          viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
          preserveAspectRatio="xMidYMid meet"
        >
          {/* Idle connection lines: thin dashed paper-tone curves
              from "you" to every non-active pin. Drawn first so the
              copper arc to the active pin paints on top. */}
          {clusters.map((p, i) => {
            if (p.active) return null;
            const mx = (YOU.x + p.vbX) / 2;
            const my = Math.min(YOU.y, p.vbY) - 28;
            return (
              <path
                key={`link-${p.key}-${i}`}
                className="worldmap-link"
                d={`M ${YOU.x} ${YOU.y} Q ${mx} ${my} ${p.vbX} ${p.vbY}`}
              />
            );
          })}
          {activePin ? (
            <path
              className="worldmap-arc"
              d={`M ${YOU.x} ${YOU.y} Q ${(YOU.x + activePin.vbX) / 2} ${
                Math.min(YOU.y, activePin.vbY) - 60
              } ${activePin.vbX} ${activePin.vbY}`}
            />
          ) : null}
          {clusters.map((p, i) => {
            const isOpen = openIdx === i;
            const isHov = i === hoverIdx;
            // A bucket with more than one server group → render as a
            // circle cluster. A singleton bucket collapses to a
            // diamond marker regardless of the level name.
            const isCluster = p.members.length > 1;
            const cls = `worldmap-pin ${p.active ? "cur" : ""} ${
              isHov ? "hov" : ""
            } ${isOpen ? "open" : ""} ${onPinClick ? "clickable" : ""} ${
              isCluster ? "is-cluster" : ""
            } lvl-${p.level}`;
            const onPinClickHandler = (e: ReactMouseEvent) => {
              if (!onPinClick) return;
              e.stopPropagation();
              if (isCluster) {
                drillToCluster(p);
                return;
              }
              const g = p.members[0].group;
              if (g.members.length > 1) {
                // Single host, multiple protocol entries — popover.
                setOpenIdx((o) => (o === i ? null : i));
              } else {
                setOpenIdx(null);
                onPinClick(g.primary.id);
              }
            };
            // Cluster radius grows with sqrt of the underlying server
            // count so a 1000-server continent doesn't dwarf a
            // 5-server country.
            const clusterR = isCluster
              ? Math.min(30, 11 + Math.sqrt(p.totalServers) * 1.5)
              : 0;
            return (
              <g
                key={p.key}
                className={cls}
                transform={`translate(${p.vbX},${p.vbY}) scale(${pinScale})`}
              >
                {isCluster ? (
                  <>
                    <circle
                      className="pin-cluster"
                      cy={-16}
                      r={clusterR}
                    />
                    <text
                      className="pin-cluster-count mono"
                      x={0}
                      y={-16}
                      textAnchor="middle"
                      dominantBaseline="central"
                      fontSize={Math.max(8, clusterR * 0.62)}
                    >
                      {p.totalServers}
                    </text>
                  </>
                ) : (
                  <>
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
                    {p.members[0].group.members.length > 1 ? (
                      <circle
                        cy={-16}
                        r={2.2}
                        className="pin-multi-dot"
                      />
                    ) : null}
                  </>
                )}
                <circle
                  cy={-16}
                  r={Math.max(20, clusterR + 4)}
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
          <g
            className="worldmap-pin you"
            transform={`translate(${YOU.x},${YOU.y}) scale(${pinScale})`}
          >
            <circle r={2.5} className="dot" />
          </g>
        </svg>
      ) : null}

      {clusters.map((p, i) => {
        const isCluster = p.members.length > 1;
        const isHov = i === hoverIdx;
        // Server-level labels hide at continent/country/city zooms to
        // prevent the "50 server names overlapping" mess the rc29 user
        // complaint called out. They reappear on hover OR once the
        // user has zoomed in to server level (scale ≥ 6).
        const hideLabel =
          !isCluster && p.level === "server" && scale < 6 && !isHov;
        if (hideLabel) return null;
        // Also hide labels for collapsed single-group clusters at
        // higher levels — they're redundant with the diamond pin and
        // clutter the continent/country view.
        if (!isCluster && p.level !== "server" && !isHov) return null;
        const label = clusterLabel(p);
        const cls = `worldmap-label ${p.active ? "cur" : ""} ${
          onPinClick ? "clickable" : ""
        } ${isCluster ? "is-cluster" : ""} lvl-${p.level}`;
        const onLabelClick = (e: ReactMouseEvent) => {
          if (!onPinClick) return;
          e.stopPropagation();
          if (isCluster) {
            drillToCluster(p);
            return;
          }
          const g = p.members[0].group;
          if (g.members.length > 1) {
            setOpenIdx((o) => (o === i ? null : i));
          } else {
            setOpenIdx(null);
            onPinClick(g.primary.id);
          }
        };
        return (
          <div
            key={`lab-${p.key}-${i}`}
            className={cls}
            style={{
              left: `${((p.vbX - MAP_VB.x) / MAP_VB.w) * 100}%`,
              top: `${((p.vbY - MAP_VB.y) / MAP_VB.h) * 100}%`,
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

      <div
        className="worldmap-you-label clickable"
        style={{
          left: `${((YOU.x - MAP_VB.x) / MAP_VB.w) * 100}%`,
          top: `${((YOU.y - MAP_VB.y) / MAP_VB.h) * 100}%`,
          transform: `translate(-50%, 12px) scale(${pinScale})`,
          transformOrigin: "center top",
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
            left: `${((hover.vbX - MAP_VB.x) / MAP_VB.w) * 100}%`,
            top: `${((hover.vbY - MAP_VB.y) / MAP_VB.h) * 100}%`,
          }}
        >
          {hover.members.length === 1 ? (
            <>
              <div className="tip-host mono">{hover.members[0].group.host}</div>
              {locText(hover.members[0].group.primary) ? (
                <div className="tip-loc">
                  {locText(hover.members[0].group.primary)}
                </div>
              ) : null}
              <div className="tip-protos mono">
                {hover.members[0].group.members
                  .map((m) => `${m.protocol}:${m.port}`)
                  .join(" · ")}
              </div>
              {hover.bestMs !== null && hover.bestMs > 0 ? (
                <div className="tip-ms mono">best {hover.bestMs}ms</div>
              ) : null}
              {onPinClick ? (
                <div className="tip-cta mono">
                  {hover.members[0].group.members.length > 1
                    ? "click to choose"
                    : "click to connect"}
                </div>
              ) : null}
            </>
          ) : (
            <>
              <div className="tip-host mono">
                {hover.label} · {hover.totalServers} servers
              </div>
              {hover.bestMs !== null && hover.bestMs > 0 ? (
                <div className="tip-ms mono">best {hover.bestMs}ms</div>
              ) : null}
              {onPinClick ? (
                <div className="tip-cta mono">click to zoom in</div>
              ) : null}
            </>
          )}
        </div>
      ) : null}

      {open && open.members.length === 1 && open.members[0].group.members.length > 1 ? (
        <>
          <div
            className="worldmap-popover-scrim"
            onClick={() => setOpenIdx(null)}
          />
          <div
            className="worldmap-popover"
            style={{
              left: `${((open.vbX - MAP_VB.x) / MAP_VB.w) * 100}%`,
              top: `${((open.vbY - MAP_VB.y) / MAP_VB.h) * 100}%`,
            }}
          >
            <div className="pop-head">
              <div className="pop-host mono">{open.members[0].group.host}</div>
              {locText(open.members[0].group.primary) ? (
                <div className="pop-loc">
                  {locText(open.members[0].group.primary)}
                </div>
              ) : null}
            </div>
            <ul className="pop-list">
              {open.members[0].group.members.map((m) => {
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
