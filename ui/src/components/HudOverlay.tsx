/**
 * HudOverlay — fixed-screen atlas decorations rendered ABOVE the
 * TransformWrapper, so they never zoom or pan with the camera.
 *
 *   ┌─────────────────────────────────────────────┐
 *   │ Plate label                                 │
 *   │                                             │
 *   │                                             │
 *   │                                             │
 *   │ Legend                Scale-bar │ Zoom lvl  │
 *   └─────────────────────────────────────────────┘
 *
 * rc40 — the compass rose was retired; the side panel already
 * occupies the top-right corner and a static north-up rose was
 * decoration that fought it for space.
 *
 * Every block is absolutely positioned against the worldmap-stage
 * (the same parent that hosts TransformWrapper), with a high
 * z-index so it floats over pins/blobs but below modal popovers.
 *
 * The overlay is intentionally a thin presentational React
 * component: all data it needs is passed via props.  This keeps
 * the SOLID boundary clean — the WorldMap is the orchestrator,
 * the HUD only knows how to draw.
 */

import type { JSX } from "react";

interface HudOverlayProps {
  /** Current TransformWrapper scale, e.g. 1.0 = fit, 12 = max. */
  scale: number;
  /** Plate-style human-readable band label. */
  plateLabel: string;
  /** Zoom-readout string ("country · 2.4×"). */
  bandReadout: string;
  /** Approximate kilometres represented by 100 viewBox units at the
   *  current zoom — drives the scale bar.  Pass `null` to hide. */
  kmPer100Vb: number | null;
  /** Click handlers for the +/− zoom buttons. */
  onZoomIn: () => void;
  onZoomOut: () => void;
  onZoomReset: () => void;
}

export function HudOverlay({
  scale,
  plateLabel,
  bandReadout,
  kmPer100Vb,
  onZoomIn,
  onZoomOut,
  onZoomReset,
}: HudOverlayProps): JSX.Element {
  const scaleBarKm =
    kmPer100Vb !== null ? Math.max(50, Math.round(kmPer100Vb / 50) * 50) : null;
  // Width of the scale bar in HUD pixels.  We want the bar to
  // represent `scaleBarKm` real-world km; if 100 vb units = X km
  // and the stage is ~600 px wide and shows ~700 vb units (after
  // accounting for the camera's ~84% fit), the px-per-km ratio is
  // not constant — we use a fixed visual width and let the label
  // carry the truth, which matches how vintage scale bars actually
  // worked (the bar's *length on the page* is fixed, the *km* it
  // represents shrinks as you zoom in).
  const barPx = scaleBarKm !== null ? Math.min(160, 60 + scale * 8) : 0;

  return (
    <div className="worldmap-hud" aria-hidden={false}>
      {/* Top-left: plate label.  Empty space when no plate so the
          masthead area stays clean. */}
      <div className="hud-plate mono">{plateLabel}</div>

      {/* Bottom-left: legend (collapsible). */}
      <Legend />

      {/* Bottom-centre: scale bar. */}
      {scaleBarKm !== null ? (
        <div className="hud-scalebar mono" aria-label={`scale ${scaleBarKm} km`}>
          <div className="hud-scalebar-track" style={{ width: `${barPx}px` }}>
            <span className="hud-scalebar-tick start" />
            <span className="hud-scalebar-tick mid" />
            <span className="hud-scalebar-tick end" />
          </div>
          <div className="hud-scalebar-label">{scaleBarKm} km</div>
        </div>
      ) : null}

      {/* Bottom-right: zoom controls + readout. */}
      <div className="hud-zoom">
        <div className="hud-zoom-btns">
          <button
            type="button"
            className="hud-zoom-btn mono"
            onClick={onZoomOut}
            title="Zoom out"
          >
            −
          </button>
          <button
            type="button"
            className="hud-zoom-btn mono"
            onClick={onZoomReset}
            title="Reset zoom"
          >
            ◇
          </button>
          <button
            type="button"
            className="hud-zoom-btn mono"
            onClick={onZoomIn}
            title="Zoom in"
          >
            +
          </button>
        </div>
        <div className="hud-zoom-readout mono">{bandReadout}</div>
      </div>
    </div>
  );
}

/** Atlas legend cartouche — explains the rc39 map glyphs.
 *
 *   – graphite tile = country/continent that hosts servers
 *   – copper tile   = currently routed-through country
 *   – hatched tile  = terra incognita (no servers in catalog)
 *   – cream diamond = station pin (idle)
 *   – copper diamond = active station pin
 *   – arc           = bearing line vous → active
 *   – vous chip     = you are here
 */
function Legend(): JSX.Element {
  return (
    <div className="hud-legend">
      <div className="hud-legend-title mono">Legenda</div>
      <ul className="hud-legend-list mono">
        <li>
          <span className="lg-glyph lg-tile-avail" /> region · has servers
        </li>
        <li>
          <span className="lg-glyph lg-tile-active" /> region · active route
        </li>
        <li>
          <span className="lg-glyph lg-tile-empty" /> terra · no servers
        </li>
        <li>
          <span className="lg-glyph lg-diamond" /> station · single host
        </li>
        <li>
          <span className="lg-glyph lg-diamond cur" /> station · active
        </li>
        <li>
          <span className="lg-glyph lg-arc" /> bearing vous → active
        </li>
        <li>
          <span className="lg-glyph lg-vous" /> vous · you are here
        </li>
      </ul>
    </div>
  );
}
