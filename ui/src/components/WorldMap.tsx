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
 * rc28 — Adaptive clustering. Pins now collapse based on their
 * on-screen pixel distance at the current zoom (see
 * ./adaptiveCluster.ts). A single isolated server stays a single
 * diamond; 50 servers in the same metro area lump into one cluster
 * pin with a count badge. Clicking a multi-member cluster animates
 * the zoom & pan to its bbox via TransformWrapper.setTransform; once
 * zoomed in, the cluster dissolves emergently into individual pins
 * because the merge threshold is now smaller in viewBox units.
 *
 * rc28 — Map full-bleed. The wrapper no longer aspect-ratio-locks
 * the stage; the map fills the parent .map container and the world
 * image is centered with object-fit/contain via `preserveAspectRatio`
 * on the SVG. Beige background covers the full container so panning
 * past the world outline reveals the same fill, not white bands.
 *
 * rc28 — Subscription filter. The optional `subscriptionFilter` prop
 * narrows the rendered server set to a single subscription so the
 * filter chips above the map are wired through one prop instead of
 * having WorldMap walk the prefs.
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
  clusterAtScale,
  resolveGroups,
  type AdaptiveCluster,
} from "./adaptiveCluster";

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

/** Cluster-aware label string. Single pin → city · ms;
 *  multi-member cluster → "{N} servers · best {ms}". */
function clusterLabel(c: AdaptiveCluster): string {
  if (c.members.length === 1) {
    const g = c.members[0].group;
    const ms = c.bestMs !== null && c.bestMs > 0 ? ` · ${c.bestMs}ms` : "";
    const city = g.primary.city || g.host;
    return `${city}${ms}`;
  }
  const ms = c.bestMs !== null && c.bestMs > 0 ? ` · ${c.bestMs}ms` : "";
  return `${c.totalServers} servers${ms}`;
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
  // Stage pixel size, captured via ResizeObserver. Adaptive
  // clustering needs real pixel dimensions to compute viewport
  // distance between projected pins. Falls back to a sensible
  // default until the observer fires once.
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

  // Project every server group to viewBox coordinates once. Only
  // re-runs when the underlying server set or active selection
  // changes — clustering at the current zoom is much cheaper.
  const { resolved, activeKey } = useMemo(
    () => resolveGroups(filtered, activeServerId),
    [filtered, activeServerId],
  );

  // Re-cluster whenever the resolved-group set, zoom, or stage
  // pixel size change. Adaptive clustering is O(N²) on the merge
  // step but N is bounded by group count (≤ a few thousand even
  // for 1000-server pools after grouping by host).
  const clusters = useMemo(
    () =>
      clusterAtScale(resolved, scale, stageSize.w, stageSize.h, activeKey),
    [resolved, scale, stageSize.w, stageSize.h, activeKey],
  );

  // Inverse zoom for SVG/HTML markers — keeps pins a constant
  // on-screen size as the user zooms in. Floor at 0.4 so the
  // 12× max zoom still shows readable diamonds.
  const pinScale = Math.max(0.4, 1 / scale);
  const activePin = clusters.find((c) => c.active);
  // Suppress the hover tooltip whenever a popover is open.
  const hover = openIdx === null && hoverIdx !== null ? clusters[hoverIdx] : null;
  const open = openIdx !== null ? clusters[openIdx] ?? null : null;

  // Drill-down: animate the transform wrapper to the bbox of the
  // tapped cluster. We translate viewBox coordinates → percent of
  // the stage size, then to pixel offsets the wrapper expects, and
  // pad ~10 % so the cluster doesn't sit flush against the edge.
  const drillToCluster = (c: AdaptiveCluster) => {
    const wrapper = transformRef.current;
    if (!wrapper) return;
    const padX = (c.bbox.maxX - c.bbox.minX) * 0.2 + 8;
    const padY = (c.bbox.maxY - c.bbox.minY) * 0.2 + 8;
    const minX = c.bbox.minX - padX;
    const maxX = c.bbox.maxX + padX;
    const minY = c.bbox.minY - padY;
    const maxY = c.bbox.maxY + padY;
    // viewBox-units → fraction of total viewBox span, → fraction of
    // stage pixels at scale=1.
    const fracW = (maxX - minX) / MAP_VB.w;
    const fracH = (maxY - minY) / MAP_VB.h;
    const targetScale = Math.min(
      12,
      Math.max(scale + 0.5, 1 / Math.max(fracW, fracH, 0.0001) * 0.85),
    );
    // Cluster centroid in stage-pixel coordinates at the new scale.
    const cx = (c.vbX - MAP_VB.x) / MAP_VB.w;
    const cy = (c.vbY - MAP_VB.y) / MAP_VB.h;
    const tx = stageSize.w / 2 - cx * stageSize.w * targetScale;
    const ty = stageSize.h / 2 - cy * stageSize.h * targetScale;
    wrapper.setTransform(tx, ty, targetScale, 350, "easeOutCubic");
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
      {/* Full-bleed stage. Holds the world image, graticule, pin
          overlay, tooltip and popover. Beige fill covers the entire
          container so panning past the world image reveals the same
          colour rather than the page background. The world.svg <image>
          uses preserveAspectRatio="xMidYMid meet" so it never
          stretches; the pin layer stays glued to the same projection
          regardless of container aspect. */}
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
            const isCluster = p.members.length > 1;
            const cls = `worldmap-pin ${p.active ? "cur" : ""} ${
              isHov ? "hov" : ""
            } ${isOpen ? "open" : ""} ${onPinClick ? "clickable" : ""} ${
              isCluster ? "is-cluster" : ""
            }`;
            const onPinClickHandler = (e: ReactMouseEvent) => {
              if (!onPinClick) return;
              e.stopPropagation();
              if (isCluster) {
                // Drill-down: animate zoom+pan onto the cluster's
                // bbox. Re-clustering at the new scale is automatic
                // (it falls out of the scale-dependent useMemo).
                drillToCluster(p);
                return;
              }
              const g = p.members[0].group;
              if (g.members.length > 1) {
                // Single host with multiple protocol entries — open
                // the picker popover so the user chooses which one.
                setOpenIdx((o) => (o === i ? null : i));
              } else {
                setOpenIdx(null);
                onPinClick(g.primary.id);
              }
            };
            // Cluster radius scales with sqrt of member count so a
            // 100-server cluster doesn't dwarf a 5-server one.
            const clusterR = isCluster
              ? Math.min(28, 10 + Math.sqrt(p.totalServers) * 1.6)
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
            transform={`translate(${YOU.x},${YOU.y})`}
          >
            <circle r={2.5} className="dot" />
          </g>
        </svg>
      ) : null}

      {clusters.map((p, i) => {
        const label = clusterLabel(p);
        const isCluster = p.members.length > 1;
        const cls = `worldmap-label ${p.active ? "cur" : ""} ${
          onPinClick ? "clickable" : ""
        } ${isCluster ? "is-cluster" : ""}`;
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
                {hover.totalServers} servers · {hover.members.length} hosts
              </div>
              {hover.bestMs !== null && hover.bestMs > 0 ? (
                <div className="tip-ms mono">best {hover.bestMs}ms</div>
              ) : null}
              {onPinClick ? (
                <div className="tip-cta mono">click to drill in</div>
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
