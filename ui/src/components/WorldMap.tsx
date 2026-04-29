/**
 * WorldMap — atlas-style world map with continent / country /
 * server clustering.
 *
 * rc37 rewrite.  Replaces the rc36 hex-bin pipeline with a
 * geographic-administrative grouping that paints actual country
 * and continent shapes drawn from Natural Earth 110m data:
 *
 *   1. resolveGroups()                 server[] → ResolvedGroup[]
 *   2. RegionClusterStrategy.cluster()  ResolvedGroup[] → Cluster[]
 *   3. renderer paints each Cluster as the matching continent /
 *      country path (or a diamond pin at the server band).
 *
 * Render layers (z-order, low → high):
 *
 *   0. world.svg base outline (flat raster of all coastlines)
 *   1. graticule (lat/lon lines)
 *   2. terra-incognita hatching for empty continents / countries
 *      (pre-painted at the current band, fades when no rooms apply)
 *   3. cluster shapes — choropleth by latency / density
 *   4. idle links + active arc
 *   5. pin layer — one diamond per cluster
 *   6. vous marker + label
 *   7. HUD overlay (compass, legend, scale, plate, zoom controls)
 *      — outside TransformWrapper, never zooms with the camera.
 *   8. tooltip / popover — also outside TransformWrapper, screen
 *      space, anti-overflow, no counter-scaling needed.
 *
 * Popovers track the cluster they were opened in by a
 * `seedServerId` (the first member's primary server id) instead of
 * cluster.id.  When the user zooms across a band boundary the
 * cluster ids change, but the seed survives — so the popover
 * follows the same group through the band transition rather than
 * vanishing and reappearing on the way back.
 */

import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type JSX,
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
import { RegionClusterStrategy } from "./cluster/RegionClusterStrategy";
import { resolveBand } from "./cluster/zoomBands";
import { latencyBucket, type Cluster } from "./cluster/types";
import {
  getCountryShapes,
  getContinentShapes,
  type CountryShape,
  type ContinentShape,
} from "./atlas/shapeStore";
import { HudOverlay } from "./HudOverlay";

interface WorldMapProps {
  servers: Server[];
  activeServerId?: string;
  bearing?: string;
  onPinClick?: (serverId: string) => void;
  myLocation?: GeoLocation;
  subscriptionFilter?: string | null;
}

// world.svg's native viewBox.
const MAP_VB = { x: 30.767, y: 241.591, w: 784.077, h: 458.627 } as const;

function project(lat: number, lon: number): { x: number; y: number } {
  return projectVB(lat, lon);
}

// Fallback "vous" anchor at lon=0, lat=20°N.
const YOU_FALLBACK = project(20, 0);

const STRATEGY = RegionClusterStrategy;

const MIN_SCALE = 1;
const MAX_SCALE = 14;

interface TformState {
  x: number;
  y: number;
  scale: number;
}

export function WorldMap({
  servers,
  activeServerId,
  bearing,
  onPinClick,
  myLocation,
  subscriptionFilter,
}: WorldMapProps): JSX.Element {
  const [hoverId, setHoverId] = useState<string | null>(null);
  const [openSeedId, setOpenSeedId] = useState<string | null>(null);
  const [vousOpen, setVousOpen] = useState(false);
  const [tform, setTform] = useState<TformState>({ x: 0, y: 0, scale: 1 });
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
  const youValid = !!(
    myLocation &&
    Number.isFinite(myLocation.lat) &&
    Number.isFinite(myLocation.lon) &&
    (myLocation.lat !== 0 || myLocation.lon !== 0)
  );

  const filtered = useMemo(() => {
    if (!subscriptionFilter) return servers;
    return servers.filter((s) => s.subscription_id === subscriptionFilter);
  }, [servers, subscriptionFilter]);

  const { resolved, activeKey } = useMemo(
    () => resolveGroups(filtered, activeServerId),
    [filtered, activeServerId],
  );

  const scale = tform.scale;
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

  // Pin counter-scale — so the diamond is roughly the same screen
  // size at any zoom level.  Has a small floor so deep zoom does
  // not collapse it to a dot.
  const pinScale = Math.max(0.25, band.pinScale / scale);

  // Server presence per ISO and per continent — drives choropleth
  // fills and "terra incognita" hatching.
  const presence = useMemo(() => {
    const countries = new Set<string>();
    const continents = new Set<string>();
    const countryServerCount = new Map<string, number>();
    const continentServerCount = new Map<string, number>();
    for (const rg of resolved) {
      if (rg.country) {
        countries.add(rg.country);
        countryServerCount.set(
          rg.country,
          (countryServerCount.get(rg.country) ?? 0) + rg.group.members.length,
        );
      }
      if (rg.continent) {
        continents.add(rg.continent);
        continentServerCount.set(
          rg.continent,
          (continentServerCount.get(rg.continent) ?? 0) +
            rg.group.members.length,
        );
      }
    }
    return {
      countries,
      continents,
      countryServerCount,
      continentServerCount,
    };
  }, [resolved]);

  // Bucket fills by relative density — splits the choropleth into
  // 4 buckets so colour reads as "few / some / many / lots".
  const densityBucket = (count: number, max: number): string => {
    if (max <= 0 || count <= 0) return "d0";
    const frac = count / max;
    if (frac < 0.25) return "d1";
    if (frac < 0.55) return "d2";
    if (frac < 0.85) return "d3";
    return "d4";
  };
  const maxCountryServers = Math.max(
    1,
    ...presence.countryServerCount.values(),
  );
  const maxContinentServers = Math.max(
    1,
    ...presence.continentServerCount.values(),
  );

  const allCountries = useMemo(() => getCountryShapes(), []);
  const allContinents = useMemo(() => getContinentShapes(), []);

  // Resolve open cluster from seed-server-id (band-stable identity).
  const openCluster: Cluster | null = useMemo(() => {
    if (!openSeedId) return null;
    for (const c of clusters) {
      for (const rg of c.members) {
        for (const m of rg.group.members) {
          if (m.id === openSeedId) return c;
        }
        if (rg.group.primary.id === openSeedId) return c;
      }
    }
    return null;
  }, [clusters, openSeedId]);

  const hover =
    !openCluster && hoverId
      ? clusters.find((c) => c.id === hoverId) ?? null
      : null;
  const activeCluster = clusters.find((c) => c.active) ?? null;

  const closePopover = () => setOpenSeedId(null);

  const openClusterByCluster = (c: Cluster) => {
    const seed = c.members[0]?.group.primary.id ?? null;
    if (seed) setOpenSeedId(seed);
  };

  /** Zoom to fit a cluster's shape with a little breathing room. */
  const drillToCluster = (c: Cluster) => {
    const wrapper = transformRef.current;
    if (!wrapper) return;
    const bw = Math.max(1, c.bbox.maxX - c.bbox.minX);
    const bh = Math.max(1, c.bbox.maxY - c.bbox.minY);
    const pad = Math.max(bw, bh) * 0.15 + 6;
    const w = bw + pad;
    const h = bh + pad;
    const fracW = w / MAP_VB.w;
    const fracH = h / MAP_VB.h;
    const fitScale = 0.85 / Math.max(fracW, fracH, 0.0001);
    const stepMin = scale * 1.4;
    const targetScale = Math.min(MAX_SCALE, Math.max(stepMin, fitScale));
    const cx = (c.vbX - MAP_VB.x) / MAP_VB.w;
    const cy = (c.vbY - MAP_VB.y) / MAP_VB.h;
    const tx = stageSize.w / 2 - cx * stageSize.w * targetScale;
    const ty = stageSize.h / 2 - cy * stageSize.h * targetScale;
    wrapper.setTransform(tx, ty, targetScale, 700, "easeOutCubic");
  };

  const zoomBy = (factor: number) => {
    const wrapper = transformRef.current;
    if (!wrapper) return;
    if (factor > 1) wrapper.zoomIn(factor - 1, 350, "easeOutCubic");
    else wrapper.zoomOut(1 - factor, 350, "easeOutCubic");
  };

  const zoomReset = () => {
    transformRef.current?.resetTransform(500, "easeOutCubic");
  };

  // Graticule.
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

  const kmPer100Vb = 4598 / scale;

  // Convert a viewBox point to screen-space CSS pixels (relative to
  // worldmap-stage top-left).  Used to anchor tooltips/popovers
  // outside the TransformWrapper without re-implementing camera.
  const vbToScreen = (vbX: number, vbY: number): { x: number; y: number } => {
    const cx = (vbX - MAP_VB.x) / MAP_VB.w;
    const cy = (vbY - MAP_VB.y) / MAP_VB.h;
    return {
      x: cx * stageSize.w * tform.scale + tform.x,
      y: cy * stageSize.h * tform.scale + tform.y,
    };
  };

  const popoverPos = openCluster
    ? clampOverlay(vbToScreen(openCluster.vbX, openCluster.vbY), stageSize, {
        w: 300,
        h: 240,
      })
    : null;
  const tooltipPos = hover
    ? clampOverlay(vbToScreen(hover.vbX, hover.vbY), stageSize, {
        w: 220,
        h: 80,
      })
    : null;
  const vousScreen = vbToScreen(YOU.x, YOU.y);
  const vousPos = vousOpen
    ? clampOverlay(vousScreen, stageSize, { w: 200, h: 80 })
    : null;

  // Render shape layer based on band: at server band, paint
  // country fills as faint outlines so individual diamonds
  // dominate; at country band, choropleth-fill all countries; at
  // continent band, paint continents as thicker silhouettes.
  const showCountryShapes = band.kind !== "continent";
  const showContinentShapes = band.kind === "continent";

  return (
    <div className="worldmap">
      <div className="worldmap-stage" ref={stageRef}>
        <TransformWrapper
          ref={transformRef}
          minScale={MIN_SCALE}
          maxScale={MAX_SCALE}
          doubleClick={{ mode: "reset" }}
          limitToBounds={true}
          centerOnInit={true}
          wheel={{ step: 0.02 }}
          pinch={{ step: 5 }}
          panning={{ velocityDisabled: true }}
          onTransform={(_ref: unknown, state: {
            positionX: number;
            positionY: number;
            scale: number;
          }) => {
            setTform({
              x: state.positionX,
              y: state.positionY,
              scale: state.scale,
            });
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
              <line
                className="eq"
                x1={clipL}
                y1={equatorY}
                x2={clipR}
                y2={equatorY}
              />
              <line
                className="eq"
                x1={meridianX}
                y1={clipT}
                x2={meridianX}
                y2={clipB}
              />
              {horizontals.map((y) => (
                <line
                  key={`h${y.toFixed(1)}`}
                  x1={clipL}
                  y1={y}
                  x2={clipR}
                  y2={y}
                />
              ))}
              {verticals.map((x) => (
                <line
                  key={`v${x.toFixed(1)}`}
                  x1={x}
                  y1={clipT}
                  x2={x}
                  y2={clipB}
                />
              ))}
            </svg>

            {/* Choropleth + terra-incognita layer.  Always paint
                every country as a thin outline so the user sees
                the political base map; fill the ones that have
                servers; hatch the rest at country band. */}
            <svg
              className="worldmap-shapes"
              viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
              preserveAspectRatio="xMidYMid meet"
            >
              <defs>
                <pattern
                  id="terra-incognita"
                  width="3"
                  height="3"
                  patternUnits="userSpaceOnUse"
                  patternTransform="rotate(45)"
                >
                  <line x1="0" y1="0" x2="0" y2="3" className="terra-stroke" />
                </pattern>
              </defs>
              {showContinentShapes
                ? allContinents.map((cs) => (
                    <ContinentShapePath
                      key={`cont-${cs.code}`}
                      shape={cs}
                      hasServers={presence.continents.has(cs.code)}
                      bucket={densityBucket(
                        presence.continentServerCount.get(cs.code) ?? 0,
                        maxContinentServers,
                      )}
                    />
                  ))
                : null}
              {showCountryShapes
                ? allCountries.map((cs) => (
                    <CountryShapePath
                      key={`cty-${cs.iso}`}
                      shape={cs}
                      hasServers={presence.countries.has(cs.iso)}
                      bucket={densityBucket(
                        presence.countryServerCount.get(cs.iso) ?? 0,
                        maxCountryServers,
                      )}
                      band={band.kind}
                    />
                  ))
                : null}
            </svg>

            {/* Highlight layer — paints the active cluster's shape
                with a copper outline.  Drawn above the base
                choropleth so it always reads as foreground. */}
            <svg
              className="worldmap-cluster-overlay"
              viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
              preserveAspectRatio="xMidYMid meet"
            >
              {clusters.map((c) => {
                if (!c.shapePath) return null;
                const isHov = c.id === hoverId;
                const isOpen = openCluster?.id === c.id;
                if (!c.active && !isHov && !isOpen) return null;
                const cls = `worldmap-cluster-shape lvl-${c.level} bucket-${latencyBucket(
                  c.bestMs,
                )} ${c.active ? "cur" : ""} ${isHov ? "hov" : ""} ${
                  isOpen ? "open" : ""
                }`;
                return <path key={`hl-${c.id}`} className={cls} d={c.shapePath} />;
              })}
            </svg>

            {/* Pin + arc layer. */}
            <svg
              className="worldmap-pins"
              viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
              preserveAspectRatio="xMidYMid meet"
            >
              {youValid ? (
                <g
                  className="worldmap-pin you"
                  transform={`translate(${YOU.x},${YOU.y}) scale(${pinScale})`}
                >
                  <circle r={1.8} className="dot" />
                </g>
              ) : null}

              {scale < 3
                ? clusters.map((c) => {
                    if (c.active) return null;
                    if (!youValid) return null;
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

              {activeCluster && youValid ? (
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
                const isOpen = openCluster?.id === c.id;
                const isHov = c.id === hoverId;
                const cls = `worldmap-pin ${c.active ? "cur" : ""} ${
                  isHov ? "hov" : ""
                } ${isOpen ? "open" : ""} ${
                  onPinClick ? "clickable" : ""
                } lvl-${c.level} bucket-${latencyBucket(c.bestMs)}`;
                const onPinClickHandler = (e: ReactMouseEvent) => {
                  if (!onPinClick) return;
                  e.stopPropagation();
                  if (isOpen) closePopover();
                  else openClusterByCluster(c);
                };
                const serverCount = c.totalServers;
                const showBadge = serverCount > 1;
                const countDisplay =
                  serverCount > 99 ? "99+" : String(serverCount);
                return (
                  <g
                    key={`pin-${c.id}`}
                    className={cls}
                    transform={`translate(${c.vbX},${c.vbY}) scale(${pinScale})`}
                    onMouseEnter={() => setHoverId(c.id)}
                    onMouseLeave={() =>
                      setHoverId((h) => (h === c.id ? null : h))
                    }
                    onClick={onPinClickHandler}
                    style={onPinClick ? { cursor: "pointer" } : undefined}
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
                  </g>
                );
              })}
            </svg>

            {youValid ? (
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
            ) : null}
          </TransformComponent>
        </TransformWrapper>

        {/* Tooltip / popover overlay — outside TransformWrapper so
            it never zooms or pans, screen-space coordinates. */}
        <div className="worldmap-overlay" aria-hidden={false}>
          {hover && tooltipPos ? (
            <div
              className={`worldmap-tooltip v-${tooltipPos.vAlign} h-${tooltipPos.hAlign}`}
              style={{
                left: `${tooltipPos.x}px`,
                top: `${tooltipPos.y}px`,
                transform: tooltipPos.transform,
                transformOrigin: tooltipPos.origin,
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

          {vousOpen && vousPos ? (
            <div
              className={`worldmap-tooltip vous-tip v-${vousPos.vAlign} h-${vousPos.hAlign}`}
              style={{
                left: `${vousPos.x}px`,
                top: `${vousPos.y}px`,
                transform: vousPos.transform,
                transformOrigin: vousPos.origin,
              }}
              onClick={(e) => e.stopPropagation()}
            >
              <div className="tip-host">It’s your location.</div>
              {myLocation ? (
                <>
                  {myLocation.city || myLocation.country ? (
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
                <div className="tip-loc italic-mute">
                  resolving via ip-api…
                </div>
              )}
              {!youValid ? (
                <div className="tip-loc italic-mute">
                  approximate · ip-geo unavailable
                </div>
              ) : null}
            </div>
          ) : null}

          {openCluster && popoverPos ? (
            <PopoverBody
              cluster={openCluster}
              pos={popoverPos}
              activeServerId={activeServerId}
              onPinClick={onPinClick}
              onDrill={() => {
                drillToCluster(openCluster);
                closePopover();
              }}
              onClose={closePopover}
            />
          ) : null}
        </div>

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

/* =============================================================
 * Sub-components
 * ============================================================= */

interface ContinentShapePathProps {
  shape: ContinentShape;
  hasServers: boolean;
  bucket: string;
}

function ContinentShapePath({
  shape,
  hasServers,
  bucket,
}: ContinentShapePathProps): JSX.Element {
  const cls = hasServers
    ? `worldmap-shape continent-shape ${bucket}`
    : "worldmap-shape continent-shape terra";
  const fill = hasServers ? undefined : "url(#terra-incognita)";
  return <path className={cls} d={shape.pathD} fill={fill} />;
}

interface CountryShapePathProps {
  shape: CountryShape;
  hasServers: boolean;
  bucket: string;
  band: "continent" | "country" | "server";
}

function CountryShapePath({
  shape,
  hasServers,
  bucket,
  band,
}: CountryShapePathProps): JSX.Element {
  const cls = `worldmap-shape country-shape band-${band} ${
    hasServers ? bucket : "terra"
  }`;
  const fill = hasServers ? undefined : "url(#terra-incognita)";
  return <path className={cls} d={shape.pathD} fill={fill} />;
}

/* =============================================================
 * Overlay positioning
 * ============================================================= */

interface OverlayPos {
  /** Anchor pixel coords (post-clamp), relative to stage. */
  x: number;
  y: number;
  /** CSS transform string (positions popover relative to anchor). */
  transform: string;
  origin: string;
  vAlign: "above" | "below";
  hAlign: "center" | "left" | "right";
}

function clampOverlay(
  anchor: { x: number; y: number },
  stage: { w: number; h: number },
  size: { w: number; h: number },
): OverlayPos {
  const margin = 12;
  const halfW = size.w / 2;
  // Horizontal: prefer center, flip to left/right if it would overflow.
  let hAlign: OverlayPos["hAlign"] = "center";
  if (anchor.x - halfW < margin) hAlign = "left";
  else if (anchor.x + halfW > stage.w - margin) hAlign = "right";
  // Vertical: prefer above, flip to below if no room.
  let vAlign: OverlayPos["vAlign"] = "above";
  if (anchor.y - size.h - margin < 0) vAlign = "below";
  // Build transform string — translate before scale, no scale.
  const yShift = vAlign === "above" ? "calc(-100% - 14px)" : "16px";
  const xShift =
    hAlign === "center"
      ? "-50%"
      : hAlign === "left"
        ? "12px"
        : "calc(-100% - 12px)";
  // Clamp anchor itself so positions outside the stage are pulled
  // back in — keeps popovers visible if user pans the map far.
  const x = Math.max(margin, Math.min(stage.w - margin, anchor.x));
  const y = Math.max(margin, Math.min(stage.h - margin, anchor.y));
  return {
    x,
    y,
    transform: `translate(${xShift}, ${yShift})`,
    origin: `${hAlign === "center" ? "center" : hAlign} ${
      vAlign === "above" ? "bottom" : "top"
    }`,
    vAlign,
    hAlign,
  };
}

/* =============================================================
 * Popover body
 * ============================================================= */

interface PopoverBodyProps {
  cluster: Cluster;
  pos: OverlayPos;
  activeServerId?: string;
  onPinClick?: (id: string) => void;
  onDrill: () => void;
  onClose: () => void;
}

function PopoverBody({
  cluster,
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

  return (
    <>
      <div className="worldmap-popover-scrim" onClick={onClose} />
      <div
        className={`worldmap-popover v-${pos.vAlign} h-${pos.hAlign}`}
        style={{
          left: `${pos.x}px`,
          top: `${pos.y}px`,
          transform: pos.transform,
          transformOrigin: pos.origin,
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
              title="Zoom into this region"
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
