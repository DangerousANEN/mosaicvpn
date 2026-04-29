/**
 * WorldMap — atlas-style world map with clustered pins.
 *
 * rc33 rewrite.  Rendering pipeline (top-to-bottom in z-order):
 *
 *   1. World outline image + graticule.
 *   2. "Blob" layer: one smoothed SVG path per parent cluster at the
 *      current zoom level.  The blob is computed from the convex hull
 *      of its members' projected pin positions, padded and splined
 *      (see ./blob.ts).  Each blob is interactive — hover lifts it to
 *      copper, click opens the popover listing every server inside.
 *   3. Idle link + active arc (unchanged from rc29).
 *   4. Pin layer: one diamond per *sub-cluster* one level deeper
 *      (continent blobs contain country diamonds, country blobs
 *      contain city diamonds, city blobs contain server diamonds).
 *      At server level — the deepest — the blob contains the
 *      pixel-merged server diamonds directly.
 *      Every diamond has the same shape; a merge-count badge appears
 *      in the upper-right corner when the diamond represents > 1
 *      underlying server.
 *   5. Popover (click) + hover tooltip.  Both are counter-scaled so
 *      they stay fixed on-screen regardless of zoom.  Popover has a
 *      "zoom into blob" button that calls drillToCluster on the
 *      parent cluster (blob-click) or on the sub-cluster (diamond-click).
 *   6. vous marker: rendered at low z-index so LAN pins show on top
 *      of the user's own location.
 *   7. Bottom-left zoom indicator ("lvl: city · 4.2×").
 *
 * rc33 — top-1000 city reference overlay is gone; only cities where
 * at least one server is present get a boundary (as city-level blob).
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
import {
  clusterAtLevel,
  levelForScale,
  pixelMergeClusters,
  projectVB,
  resolveGroups,
  subClusters,
  type LevelCluster,
  type MapLevel,
} from "./levelCluster";
import { blobPath } from "./blob";

interface WorldMapProps {
  servers: Server[];
  activeServerId?: string;
  /** Optional caption shown in the top-right corner (e.g. current bearing). */
  bearing?: string;
  /** Connect handler invoked with the chosen server id. Invoked from
   *  the popover only — direct diamond clicks always open the
   *  popover first. Omit to render non-clickable pins (hover still
   *  works). */
  onPinClick?: (serverId: string) => void;
  /** User's resolved IP-geo location (from /v1/status). */
  myLocation?: GeoLocation;
  /** When set, only servers belonging to the subscription with this
   *  ID are rendered. Drives the rc28 filter chips above the map. */
  subscriptionFilter?: string | null;
}

// world.svg's native viewBox.
const MAP_VB = { x: 30.767, y: 241.591, w: 784.077, h: 458.627 } as const;

function project(lat: number, lon: number): { x: number; y: number } {
  return projectVB(lat, lon);
}

// Fallback "vous" anchor at lon=0, lat=20°N.
const YOU_FALLBACK = project(20, 0);

function levelAbbrev(level: MapLevel): string {
  switch (level) {
    case "continent":
      return "continent";
    case "country":
      return "country";
    case "city":
      return "city";
    case "server":
      return "server";
  }
}

// Per-level blob expansion offset in viewBox units.  Bigger blobs
// at higher zoom levels so a continent hugs loosely while a server
// cluster traces its pins tightly.  Values picked empirically.
function blobOffsetForLevel(level: MapLevel): number {
  switch (level) {
    // rc34 — smaller offsets so blobs trace their cluster tight.
    // A 14 vb-unit expansion at continent level read as "blobs of
    // Europe and Asia glued together".
    case "continent":
      return 10;
    case "country":
      return 5;
    case "city":
      return 4;
    case "server":
      return 2.4;
  }
}

interface PinEntry {
  cluster: LevelCluster;
  // The drill target — for a sub-diamond this is the sub-cluster
  // itself; for the deepest server-level entries it's the cluster.
  drillTarget: LevelCluster;
  // The parent blob this diamond sits inside (null at server level
  // when there is no outer blob).
  parent: LevelCluster | null;
}

export function WorldMap({
  servers,
  activeServerId,
  bearing,
  onPinClick,
  myLocation,
  subscriptionFilter,
}: WorldMapProps): JSX.Element {
  const [hoverPinIdx, setHoverPinIdx] = useState<number | null>(null);
  const [hoverBlobIdx, setHoverBlobIdx] = useState<number | null>(null);
  const [openPinIdx, setOpenPinIdx] = useState<number | null>(null);
  const [openBlobIdx, setOpenBlobIdx] = useState<number | null>(null);
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

  const level = levelForScale(scale);

  // Parent clusters at the current zoom level — these get painted as
  // blobs.  rc34 — pixel-merge runs on ALL levels so Benelux-type
  // country stacking or dense continent-side-by-side visits don't
  // produce overlapping blobs.  The merge threshold scales with the
  // band: coarse bands get more aggressive merging.
  const parents = useMemo(() => {
    const base = clusterAtLevel(resolved, level, activeKey);
    const mergePx =
      level === "continent" ? 72 : level === "country" ? 56 : 36;
    return pixelMergeClusters(
      base,
      scale,
      stageSize.w,
      stageSize.h,
      mergePx,
    );
  }, [resolved, level, activeKey, scale, stageSize.w, stageSize.h]);

  // Pin list: one diamond per sub-cluster (next level down). At
  // server level the "sub-cluster" is the cluster itself because
  // there's nowhere deeper to drill.
  const pins: PinEntry[] = useMemo(() => {
    const out: PinEntry[] = [];
    for (const p of parents) {
      if (p.level === "server") {
        out.push({ cluster: p, drillTarget: p, parent: null });
        continue;
      }
      const rawSubs = subClusters(p, activeKey);
      // rc34 — same pixel-merge treatment on the child diamonds so a
      // continent blob doesn't end up with 40 overlapping country
      // markers, and a country blob doesn't end up with 20 city-sized
      // bumps.  Child threshold is half the parent band.
      const childMerge =
        p.level === "continent" ? 44 : p.level === "country" ? 36 : 32;
      const subs = pixelMergeClusters(
        rawSubs,
        scale,
        stageSize.w,
        stageSize.h,
        childMerge,
      );
      if (subs.length === 0) {
        out.push({ cluster: p, drillTarget: p, parent: null });
      } else {
        for (const s of subs) {
          out.push({ cluster: s, drillTarget: s, parent: p });
        }
      }
    }
    return out;
  }, [parents, activeKey, scale, stageSize.w, stageSize.h]);

  const pinScale = Math.max(0.4, 1 / scale);
  const activePin = pins.find((p) => p.cluster.active)?.cluster ?? null;

  const openPin = openPinIdx !== null ? pins[openPinIdx]?.cluster ?? null : null;
  const openBlob =
    openBlobIdx !== null ? parents[openBlobIdx] ?? null : null;
  const open = openPin ?? openBlob;
  const openDrill =
    openPinIdx !== null
      ? pins[openPinIdx]?.drillTarget ?? null
      : openBlob;

  const hoverPin =
    openPinIdx === null && openBlobIdx === null && hoverPinIdx !== null
      ? pins[hoverPinIdx]?.cluster ?? null
      : null;
  const hoverBlob =
    openPinIdx === null && openBlobIdx === null && hoverBlobIdx !== null && hoverPinIdx === null
      ? parents[hoverBlobIdx] ?? null
      : null;
  const hover = hoverPin ?? hoverBlob;

  const closePopovers = () => {
    setOpenPinIdx(null);
    setOpenBlobIdx(null);
  };

  /** Zoom-to-fit on a cluster bbox. Proportional to bbox span, with
   *  a step-forward floor (×1.2) so clicks never zoom out. */
  const drillToCluster = (c: LevelCluster) => {
    const wrapper = transformRef.current;
    if (!wrapper) return;
    const w = Math.max(1, c.bbox.maxX - c.bbox.minX);
    const h = Math.max(1, c.bbox.maxY - c.bbox.minY);
    const fracW = w / MAP_VB.w;
    const fracH = h / MAP_VB.h;
    const fitScale = 0.85 / Math.max(fracW, fracH, 0.0001);
    const stepMin = scale * 1.2;
    const targetScale = Math.min(12, Math.max(stepMin, fitScale));
    const midX = (c.bbox.minX + c.bbox.maxX) / 2;
    const midY = (c.bbox.minY + c.bbox.maxY) / 2;
    const cx = (midX - MAP_VB.x) / MAP_VB.w;
    const cy = (midY - MAP_VB.y) / MAP_VB.h;
    const tx = stageSize.w / 2 - cx * stageSize.w * targetScale;
    const ty = stageSize.h / 2 - cy * stageSize.h * targetScale;
    wrapper.setTransform(tx, ty, targetScale, 600, "easeOut");
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

  // Precompute blob paths for the current level.
  const blobPaths = useMemo(() => {
    const offset = blobOffsetForLevel(level);
    return parents.map((p) =>
      blobPath(
        p.members.map((m) => ({ vbX: m.vbX, vbY: m.vbY })),
        offset,
        offset * 0.8,
      ),
    );
  }, [parents, level]);

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

            {/* Blobs. One per parent cluster. Interactive: hover
                highlights copper, click opens the popover for the
                parent. */}
            {parents.length > 0 ? (
              <svg
                className="worldmap-blobs"
                viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
                preserveAspectRatio="xMidYMid meet"
              >
                {parents.map((p, i) => {
                  const d = blobPaths[i];
                  if (!d) return null;
                  const isActive = p.active;
                  const isHov = i === hoverBlobIdx;
                  const isOpen = i === openBlobIdx;
                  const cls = `worldmap-blob lvl-${p.level} ${
                    isActive ? "cur" : ""
                  } ${isHov ? "hov" : ""} ${isOpen ? "open" : ""}`;
                  return (
                    <path
                      key={`blob-${p.key}`}
                      className={cls}
                      d={d}
                      onMouseEnter={() => setHoverBlobIdx(i)}
                      onMouseLeave={() =>
                        setHoverBlobIdx((h) => (h === i ? null : h))
                      }
                      onClick={(e) => {
                        if (!onPinClick) return;
                        e.stopPropagation();
                        setOpenPinIdx(null);
                        setOpenBlobIdx((o) => (o === i ? null : i));
                      }}
                    />
                  );
                })}
              </svg>
            ) : null}

            {/* Pins + idle/active arcs share the same SVG so the arc
                sits under the diamonds. */}
            {pins.length > 0 ? (
              <svg
                className="worldmap-pins"
                viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
                preserveAspectRatio="xMidYMid meet"
              >
                {/* vous marker first so every server pin paints on top
                    of the user's own location (rc33 — user reported
                    "vous" covering server diamonds at high zoom). */}
                <g
                  className="worldmap-pin you"
                  transform={`translate(${YOU.x},${YOU.y}) scale(${pinScale})`}
                >
                  <circle r={1.8} className="dot" />
                </g>
                {pins.map(({ cluster: p }, i) => {
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
                {pins.map((entry, i) => {
                  const p = entry.cluster;
                  const isOpen = openPinIdx === i;
                  const isHov = i === hoverPinIdx;
                  const cls = `worldmap-pin ${p.active ? "cur" : ""} ${
                    isHov ? "hov" : ""
                  } ${isOpen ? "open" : ""} ${
                    onPinClick ? "clickable" : ""
                  } lvl-${p.level}`;
                  const onPinClickHandler = (e: ReactMouseEvent) => {
                    if (!onPinClick) return;
                    e.stopPropagation();
                    setOpenBlobIdx(null);
                    setOpenPinIdx((o) => (o === i ? null : i));
                  };
                  const serverCount = p.totalServers;
                  const countDisplay =
                    serverCount > 9 ? "9+" : String(serverCount);
                  const showBadge = serverCount > 1;
                  return (
                    <g
                      key={`${p.key}-${i}`}
                      className={cls}
                      transform={`translate(${p.vbX},${p.vbY}) scale(${pinScale})`}
                    >
                      <line x1={0} y1={0} x2={0} y2={-6} className="pin-stem" />
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
                            r={2.6}
                          />
                          <text
                            className="pin-badge-count mono"
                            x={5.5}
                            y={-13.4}
                            textAnchor="middle"
                            dominantBaseline="central"
                            fontSize={3.6}
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
                        onMouseEnter={() => setHoverPinIdx(i)}
                        onMouseLeave={() =>
                          setHoverPinIdx((h) => (h === i ? null : h))
                        }
                        onClick={onPinClickHandler}
                      />
                    </g>
                  );
                })}
              </svg>
            ) : null}

            {/* vous label — click to open the info tooltip. */}
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

            {/* Hover tooltip — single source regardless of whether the
                hover target is a blob or a diamond. */}
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
                  {hover.label} · {hover.totalServers} server{hover.totalServers === 1 ? "" : "s"}
                </div>
                {hover.bestMs !== null && hover.bestMs > 0 ? (
                  <div className="tip-ms mono">best {hover.bestMs}ms</div>
                ) : null}
                {onPinClick ? (
                  <div className="tip-cta mono">click to choose</div>
                ) : null}
              </div>
            ) : null}

            {/* Popover. Renders the full server list (scrolling when
                tall) with a zoom-into-blob button up top. */}
            {open && openDrill ? (() => {
              type Row = {
                id: string;
                host: string;
                proto: string;
                port: number;
                ms: string;
                isActive: boolean;
              };
              const rows: Row[] = [];
              for (const rg of open.members) {
                const g = rg.group;
                for (const m of g.members) {
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
                    isActive: m.id === activeServerId,
                  });
                }
              }
              rows.sort((a, b) => {
                if (a.isActive !== b.isActive) return a.isActive ? -1 : 1;
                const aMs = parseInt(a.ms, 10);
                const bMs = parseInt(b.ms, 10);
                const aNum = Number.isFinite(aMs) ? aMs : Number.POSITIVE_INFINITY;
                const bNum = Number.isFinite(bMs) ? bMs : Number.POSITIVE_INFINITY;
                return aNum - bNum;
              });
              const scrollClass = rows.length > 6 ? "pop-list-scroll" : "";
              return (
                <>
                  <div className="worldmap-popover-scrim" onClick={closePopovers} />
                  <div
                    className="worldmap-popover"
                    style={{
                      left: `${((open.vbX - MAP_VB.x) / MAP_VB.w) * 100}%`,
                      top: `${((open.vbY - MAP_VB.y) / MAP_VB.h) * 100}%`,
                      transform: `translate(-50%, calc(-100% - 14px)) scale(${pinScale})`,
                      transformOrigin: "center bottom",
                    }}
                    onClick={(e) => e.stopPropagation()}
                  >
                    <div className="pop-head">
                      <div className="pop-host mono">
                        {open.label} · {open.totalServers} servers
                      </div>
                      <button
                        type="button"
                        className="pop-zoom-btn mono"
                        onClick={() => {
                          drillToCluster(openDrill);
                          closePopovers();
                        }}
                      >
                        zoom into blob
                      </button>
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
                              closePopovers();
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
            })() : null}

            {bearing ? <div className="worldmap-bearing">{bearing}</div> : null}
          </TransformComponent>
        </TransformWrapper>

        {/* Zoom indicator — rc35 moved OUT of TransformComponent so
            panning the camera does not drag the readout off-screen.
            Pinned to the stage's absolute bottom-left; no
            counter-scaling needed since we live outside the zoom
            transform. */}
        <div className="worldmap-zoom-indicator mono">
          lvl: {levelAbbrev(level)} · {scale.toFixed(1)}×
        </div>
      </div>
    </div>
  );
}
