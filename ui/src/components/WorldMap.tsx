/**
 * WorldMap — atlas-style world map with hex-tiled clusters.
 *
 * rc36 rewrite.  Replaces the rc35 nested blob/diamond hierarchy
 * with a single-level hex-bin clustering pipeline:
 *
 *   1. resolveGroups()           server[] → ResolvedGroup[]
 *   2. HexClusterStrategy.cluster()  ResolvedGroup[] → Cluster[]
 *   3. renderer paints each Cluster as a hex polygon + diamond pin
 *
 * Hex cells never overlap by construction, so the pixel-merge pass
 * is gone and clusters never visually collide regardless of how
 * dense the data is in one metro.  Multi-resolution comes from
 * ZoomBands — band ID is part of every cluster's stable id, so
 * popover state survives band switches and re-renders cleanly.
 *
 * Render layers (z-order, low → high):
 *
 *   0. world.svg outline (image)
 *   1. graticule (lat/lon lines)
 *   2. hex grid: one polygon per Cluster
 *   3. idle links + active arc
 *   4. pin layer: one diamond per Cluster, badge if >1 server
 *   5. vous marker + label + tooltip
 *   6. hover tooltip / popover (counter-scaled, anti-overflow)
 *   7. HUD overlay (compass, legend, scale, plate, zoom controls)
 *
 * The HUD lives OUTSIDE TransformWrapper, so it stays anchored to
 * the stage corners — never zooms or pans with the camera.
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
import { resolveGroups, projectVB } from "./cluster/resolveGroups";
import { HexClusterStrategy } from "./cluster/HexClusterStrategy";
import { resolveBand } from "./cluster/zoomBands";
import { latencyBucket, type Cluster } from "./cluster/types";
import { HudOverlay } from "./HudOverlay";

interface WorldMapProps {
  servers: Server[];
  activeServerId?: string;
  /** Optional caption (e.g. current bearing). Shown in the HUD. */
  bearing?: string;
  /** Connect handler. Invoked from the popover only — direct
   *  diamond clicks open the popover first. */
  onPinClick?: (serverId: string) => void;
  /** User's IP-geo location (from /v1/status). */
  myLocation?: GeoLocation;
  /** Subscription filter — only matching servers are rendered. */
  subscriptionFilter?: string | null;
}

// world.svg's native viewBox.
const MAP_VB = { x: 30.767, y: 241.591, w: 784.077, h: 458.627 } as const;

function project(lat: number, lon: number): { x: number; y: number } {
  return projectVB(lat, lon);
}

// Fallback "vous" anchor at lon=0, lat=20°N.
const YOU_FALLBACK = project(20, 0);

const STRATEGY = new HexClusterStrategy();

export function WorldMap({
  servers,
  activeServerId,
  bearing,
  onPinClick,
  myLocation,
  subscriptionFilter,
}: WorldMapProps): JSX.Element {
  // State stored by stable cluster.id (not array index).  This
  // single change kills the rc35 popover-flickers-on-refresh bug:
  // re-clustering returns clusters with the same ids, so the
  // popover/hover stays anchored to the right bucket.
  const [hoverId, setHoverId] = useState<string | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
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

  const YOU = myLocation
    ? project(myLocation.lat, myLocation.lon)
    : YOU_FALLBACK;

  const filtered = useMemo(() => {
    if (!subscriptionFilter) return servers;
    return servers.filter((s) => s.subscription_id === subscriptionFilter);
  }, [servers, subscriptionFilter]);

  const { resolved, activeKey } = useMemo(
    () => resolveGroups(filtered, activeServerId),
    [filtered, activeServerId],
  );

  const band = resolveBand(scale);

  const clusters = useMemo(
    () =>
      STRATEGY.cluster(resolved, {
        scale,
        stageW: stageSize.w,
        stageH: stageSize.h,
        activeKey,
      }),
    [resolved, scale, stageSize.w, stageSize.h, activeKey],
  );

  // Counter-scale: keep pins / labels / popovers a constant pixel
  // size regardless of zoom level.  Multiplied by the band's
  // pinScale so silhouettes are smaller at low zoom (continent
  // overview) and larger at high zoom (server-level pick).
  const pinScale = Math.max(0.35, band.pinScale / scale);

  const open = openId ? clusters.find((c) => c.id === openId) ?? null : null;
  const hover =
    !open && hoverId ? clusters.find((c) => c.id === hoverId) ?? null : null;
  const activeCluster = clusters.find((c) => c.active) ?? null;

  const closePopover = () => setOpenId(null);

  /** Zoom-to-fit a cluster's hex with the next band's geometry, so
   *  one click always reveals more detail. */
  const drillToCluster = (c: Cluster) => {
    const wrapper = transformRef.current;
    if (!wrapper) return;
    // Use hex bbox padded by edge length so the next band has
    // room to breathe.  This tends to reveal 1-2 levels of
    // additional hexes per click.
    const R = band.hexR;
    const w = Math.max(1, c.bbox.maxX - c.bbox.minX) + R * 0.5;
    const h = Math.max(1, c.bbox.maxY - c.bbox.minY) + R * 0.5;
    const fracW = w / MAP_VB.w;
    const fracH = h / MAP_VB.h;
    const fitScale = 0.85 / Math.max(fracW, fracH, 0.0001);
    const stepMin = scale * 1.4;
    const targetScale = Math.min(12, Math.max(stepMin, fitScale));
    const cx = (c.vbX - MAP_VB.x) / MAP_VB.w;
    const cy = (c.vbY - MAP_VB.y) / MAP_VB.h;
    const tx = stageSize.w / 2 - cx * stageSize.w * targetScale;
    const ty = stageSize.h / 2 - cy * stageSize.h * targetScale;
    wrapper.setTransform(tx, ty, targetScale, 700, "easeOutCubic");
  };

  const zoomBy = (factor: number) => {
    const wrapper = transformRef.current;
    if (!wrapper) return;
    const next = Math.min(12, Math.max(1, scale * factor));
    if (factor > 1) wrapper.zoomIn(factor - 1, 350, "easeOutCubic");
    else wrapper.zoomOut(1 - factor, 350, "easeOutCubic");
    void next;
  };

  const zoomReset = () => {
    transformRef.current?.resetTransform(500, "easeOutCubic");
  };

  // Graticule constants.
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

  // Approximate km represented by 100 viewBox units at the
  // equator.  Equirect projection: 1 deg ≈ 111 km, and our
  // LON_SCALE = 2.414 vb-units/deg.  So 100 vb units ≈ 100/2.414
  // deg ≈ 41.4 deg ≈ 4598 km at the equator, divided by current
  // zoom scale to get the on-screen km.
  const kmPer100Vb = 4598 / scale;

  const popoverPos = open ? clampPopover(open.vbX, open.vbY, stageSize) : null;

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
          wheel={{ step: 0.06 }}
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

            {/* Hex grid — one polygon per cluster. */}
            <svg
              className="worldmap-hexes"
              viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
              preserveAspectRatio="xMidYMid meet"
            >
              {clusters.map((c) => {
                const isHov = c.id === hoverId;
                const isOpen = c.id === openId;
                const cls = `worldmap-hex lvl-${c.level} bucket-${latencyBucket(
                  c.bestMs,
                )} ${c.active ? "cur" : ""} ${isHov ? "hov" : ""} ${
                  isOpen ? "open" : ""
                }`;
                return (
                  <path
                    key={c.id}
                    className={cls}
                    d={c.shapePath}
                    onMouseEnter={() => setHoverId(c.id)}
                    onMouseLeave={() =>
                      setHoverId((h) => (h === c.id ? null : h))
                    }
                    onClick={(e) => {
                      if (!onPinClick) return;
                      e.stopPropagation();
                      setOpenId((o) => (o === c.id ? null : c.id));
                    }}
                  />
                );
              })}
            </svg>

            {/* Pin + arc layer.  vous goes first so server pins
                paint on top of the user's location. */}
            <svg
              className="worldmap-pins"
              viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
              preserveAspectRatio="xMidYMid meet"
            >
              <g
                className="worldmap-pin you"
                transform={`translate(${YOU.x},${YOU.y}) scale(${pinScale})`}
              >
                <circle r={1.8} className="dot" />
              </g>

              {/* Idle quadratic links from "you" to each cluster.
                  Skipped at high zoom so the screen doesn't fill
                  with arcs. */}
              {scale < 3
                ? clusters.map((c) => {
                    if (c.active) return null;
                    const mx = (YOU.x + c.vbX) / 2;
                    const my = Math.min(YOU.y, c.vbY) - 28;
                    return (
                      <path
                        key={`link-${c.id}`}
                        className="worldmap-link"
                        d={`M ${YOU.x} ${YOU.y} Q ${mx} ${my} ${c.vbX} ${c.vbY}`}
                      />
                    );
                  })
                : null}

              {activeCluster ? (
                <path
                  className="worldmap-arc"
                  d={`M ${YOU.x} ${YOU.y} Q ${
                    (YOU.x + activeCluster.vbX) / 2
                  } ${
                    Math.min(YOU.y, activeCluster.vbY) - 60
                  } ${activeCluster.vbX} ${activeCluster.vbY}`}
                />
              ) : null}

              {clusters.map((c) => {
                const isOpen = c.id === openId;
                const isHov = c.id === hoverId;
                const cls = `worldmap-pin ${c.active ? "cur" : ""} ${
                  isHov ? "hov" : ""
                } ${isOpen ? "open" : ""} ${
                  onPinClick ? "clickable" : ""
                } lvl-${c.level} bucket-${latencyBucket(c.bestMs)}`;
                const onPinClickHandler = (e: ReactMouseEvent) => {
                  if (!onPinClick) return;
                  e.stopPropagation();
                  setOpenId((o) => (o === c.id ? null : c.id));
                };
                const serverCount = c.totalServers;
                const showBadge = serverCount > 1;
                // Two-digit cap: "9+" past 99 to keep the badge
                // glyph readable.  Full count lives in the popover.
                const countDisplay =
                  serverCount > 99 ? "99+" : String(serverCount);
                return (
                  <g
                    key={`pin-${c.id}`}
                    className={cls}
                    transform={`translate(${c.vbX},${c.vbY}) scale(${pinScale})`}
                  >
                    <line
                      x1={0}
                      y1={0}
                      x2={0}
                      y2={-6}
                      className="pin-stem"
                    />
                    <path
                      className="pin-diamond"
                      d="M 0 -6 L 4 -10 L 0 -14 L -4 -10 Z"
                    />
                    {showBadge ? (
                      <>
                        <circle
                          className="pin-badge"
                          cx={5.5}
                          cy={-13.5}
                          r={countDisplay.length > 2 ? 3.4 : 2.6}
                        />
                        <text
                          className="pin-badge-count mono"
                          x={5.5}
                          y={-13.4}
                          textAnchor="middle"
                          dominantBaseline="central"
                          fontSize={countDisplay.length > 2 ? 3.0 : 3.6}
                        >
                          {countDisplay}
                        </text>
                      </>
                    ) : null}
                    <circle
                      cy={-10}
                      r={9}
                      fill="transparent"
                      style={onPinClick ? { cursor: "pointer" } : undefined}
                      onMouseEnter={() => setHoverId(c.id)}
                      onMouseLeave={() =>
                        setHoverId((h) => (h === c.id ? null : h))
                      }
                      onClick={onPinClickHandler}
                    />
                  </g>
                );
              })}
            </svg>

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
                  transform: `translate(-50%, calc(-100% - 14px)) scale(${pinScale})`,
                  transformOrigin: "center bottom",
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
                      {myLocation.lat.toFixed(2)}, {myLocation.lon.toFixed(2)}
                    </div>
                  </>
                ) : (
                  <div className="tip-loc italic-mute">resolving via ip-api…</div>
                )}
              </div>
            ) : null}

            {hover && !open ? (
              <div
                className="worldmap-tooltip"
                style={{
                  left: `${((hover.vbX - MAP_VB.x) / MAP_VB.w) * 100}%`,
                  top: `${((hover.vbY - MAP_VB.y) / MAP_VB.h) * 100}%`,
                  transform: `translate(-50%, calc(-100% - 14px)) scale(${pinScale})`,
                  transformOrigin: "center bottom",
                }}
              >
                <div className="tip-host mono">
                  {hover.label} · {hover.totalServers} server
                  {hover.totalServers === 1 ? "" : "s"}
                </div>
                {hover.bestMs !== null && hover.bestMs > 0 ? (
                  <div className="tip-ms mono">best {hover.bestMs}ms</div>
                ) : null}
                {onPinClick ? (
                  <div className="tip-cta mono">click to choose</div>
                ) : null}
              </div>
            ) : null}

            {open && popoverPos ? (
              <PopoverBody
                cluster={open}
                pinScale={pinScale}
                pos={popoverPos}
                activeServerId={activeServerId}
                onPinClick={onPinClick}
                onDrill={() => {
                  drillToCluster(open);
                  closePopover();
                }}
                onClose={closePopover}
              />
            ) : null}
          </TransformComponent>
        </TransformWrapper>

        {/* HUD — fixed-screen overlay. */}
        <HudOverlay
          scale={scale}
          plateLabel={band.plateLabel}
          bandReadout={STRATEGY.bandLabel({
            scale,
            stageW: stageSize.w,
            stageH: stageSize.h,
            activeKey,
          })}
          kmPer100Vb={kmPer100Vb}
          onZoomIn={() => zoomBy(1.6)}
          onZoomOut={() => zoomBy(1 / 1.6)}
          onZoomReset={zoomReset}
        />

        {bearing ? (
          <div className="worldmap-bearing mono">{bearing}</div>
        ) : null}
      </div>
    </div>
  );
}

interface PopoverPos {
  /** Anchor X in % of stage width.  May be re-anchored to the
   *  opposite side if the natural anchor would overflow. */
  leftPct: number;
  topPct: number;
  /** translate keyword: "above" (popover floats above the anchor)
   *  or "below" (popover drops below).  Picked based on which
   *  side has more vertical room. */
  vAlign: "above" | "below";
  /** translate keyword: "center" / "left" / "right" — picks
   *  whether the anchor is at the popover's centre, left, or
   *  right edge.  Right edge means the popover sits to the LEFT
   *  of the anchor (avoids overflow on the right side of the
   *  stage). */
  hAlign: "center" | "left" | "right";
}

const POPOVER_W_GUESS = 280;
const POPOVER_H_GUESS = 220;

function clampPopover(
  vbX: number,
  vbY: number,
  stage: { w: number; h: number },
): PopoverPos {
  // Convert vb anchor to fraction-of-stage.
  const xPct = ((vbX - MAP_VB.x) / MAP_VB.w) * 100;
  const yPct = ((vbY - MAP_VB.y) / MAP_VB.h) * 100;
  // Anchor in CSS px (approximate — TransformComponent applies
  // its own scale on top, but the popover is counter-scaled to
  // 1/scale * pinScale and the stage-size guess is good enough
  // for edge avoidance).
  const xPx = (xPct / 100) * stage.w;
  const yPx = (yPct / 100) * stage.h;
  const margin = 12;
  const halfW = POPOVER_W_GUESS / 2;
  const fullH = POPOVER_H_GUESS;
  let hAlign: PopoverPos["hAlign"] = "center";
  if (xPx - halfW < margin) hAlign = "left";
  else if (xPx + halfW > stage.w - margin) hAlign = "right";
  let vAlign: PopoverPos["vAlign"] = "above";
  if (yPx - fullH < margin) vAlign = "below";
  return { leftPct: xPct, topPct: yPct, vAlign, hAlign };
}

interface PopoverBodyProps {
  cluster: Cluster;
  pinScale: number;
  pos: PopoverPos;
  activeServerId?: string;
  onPinClick?: (id: string) => void;
  onDrill: () => void;
  onClose: () => void;
}

function PopoverBody({
  cluster,
  pinScale,
  pos,
  activeServerId,
  onPinClick,
  onDrill,
  onClose,
}: PopoverBodyProps): JSX.Element {
  type Row = {
    id: string;
    host: string;
    proto: string;
    port: number;
    ms: string;
    msNum: number;
    isActive: boolean;
  };
  const rows: Row[] = [];
  for (const rg of cluster.members) {
    const g = rg.group;
    for (const m of g.members) {
      const num =
        m.last_test_ms !== undefined && m.last_test_ms > 0
          ? m.last_test_ms
          : Number.POSITIVE_INFINITY;
      rows.push({
        id: m.id,
        host: g.host,
        proto: m.protocol ?? "",
        port: m.port ?? 0,
        ms:
          m.last_test_ms !== undefined && m.last_test_ms > 0
            ? `${m.last_test_ms}ms`
            : m.last_test_error
              ? "err"
              : "—",
        msNum: num,
        isActive: m.id === activeServerId,
      });
    }
  }
  rows.sort((a, b) => {
    if (a.isActive !== b.isActive) return a.isActive ? -1 : 1;
    return a.msNum - b.msNum;
  });
  const fastest = rows.find((r) => !r.isActive && Number.isFinite(r.msNum));
  const scrollClass = rows.length > 6 ? "pop-list-scroll" : "";

  // Build the transform string from the clamped position.
  const yShift =
    pos.vAlign === "above" ? "calc(-100% - 14px)" : "16px";
  const xShift =
    pos.hAlign === "center"
      ? "-50%"
      : pos.hAlign === "left"
        ? "12px"
        : "calc(-100% - 12px)";
  const origin =
    pos.vAlign === "above"
      ? `${pos.hAlign === "center" ? "center" : pos.hAlign} bottom`
      : `${pos.hAlign === "center" ? "center" : pos.hAlign} top`;

  return (
    <>
      <div className="worldmap-popover-scrim" onClick={onClose} />
      <div
        className={`worldmap-popover v-${pos.vAlign} h-${pos.hAlign}`}
        style={{
          left: `${pos.leftPct}%`,
          top: `${pos.topPct}%`,
          transform: `translate(${xShift}, ${yShift}) scale(${pinScale})`,
          transformOrigin: origin,
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="pop-head">
          <div className="pop-host mono" title={cluster.label}>
            {cluster.label} · {cluster.totalServers}
            {cluster.totalServers === 1 ? " server" : " servers"}
          </div>
          <div className="pop-actions">
            {onPinClick && fastest ? (
              <button
                type="button"
                className="pop-fast-btn mono"
                onClick={() => {
                  onPinClick(fastest.id);
                  onClose();
                }}
                title={`Connect to fastest in ${cluster.label}`}
              >
                fastest →
              </button>
            ) : null}
            <button
              type="button"
              className="pop-zoom-btn mono"
              onClick={onDrill}
              title="Zoom into this hex"
            >
              zoom
            </button>
          </div>
        </div>
        <ul className={`pop-list ${scrollClass}`}>
          {rows.map((r) => (
            <li key={r.id} className={r.isActive ? "is-active" : ""}>
              <span className="pop-proto mono" title={r.host}>
                {r.host}
              </span>
              <span className="pop-ms mono">
                {r.proto}:{r.port} · {r.ms}
              </span>
              <button
                type="button"
                className="pop-go mono"
                disabled={!onPinClick || r.isActive}
                onClick={(e) => {
                  e.stopPropagation();
                  if (!onPinClick) return;
                  onClose();
                  onPinClick(r.id);
                }}
              >
                {r.isActive ? "current" : "connect"}
              </button>
            </li>
          ))}
        </ul>
      </div>
    </>
  );
}
