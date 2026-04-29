/**
 * HudOverlay — fixed-screen atlas decorations rendered ABOVE the
 * TransformWrapper, so they never zoom or pan with the camera.
 *
 *   ┌─────────────────────────────────────────────┐
 *   │ Plate label                       Compass   │
 *   │                                             │
 *   │                                             │
 *   │                                             │
 *   │ Legend                Scale-bar │ Zoom lvl  │
 *   └─────────────────────────────────────────────┘
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

      {/* Top-right: compass rose. */}
      <CompassRose />

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

/** Minimal eight-pointed mariner's rose, pure SVG, no deps.  The
 *  compass always points north-up because the world map is
 *  equirectangular and never rotates. */
function CompassRose(): JSX.Element {
  return (
    <svg
      className="hud-compass"
      viewBox="-50 -50 100 100"
      width={68}
      height={68}
      aria-hidden="true"
    >
      <circle r={46} className="rose-ring" />
      <circle r={40} className="rose-ring inner" />
      {/* Eight rays — long N/S/E/W, short NE/NW/SE/SW. */}
      {Array.from({ length: 8 }).map((_, i) => {
        const a = (i * Math.PI) / 4;
        const r1 = 6;
        const r2 = i % 2 === 0 ? 38 : 22;
        return (
          <line
            key={i}
            x1={Math.cos(a) * r1}
            y1={Math.sin(a) * r1}
            x2={Math.cos(a) * r2}
            y2={Math.sin(a) * r2}
            className={i % 2 === 0 ? "rose-ray cardinal" : "rose-ray"}
          />
        );
      })}
      {/* Triangle pointer for north. */}
      <path className="rose-needle north" d="M -3 -8 L 0 -42 L 3 -8 Z" />
      <path className="rose-needle south" d="M -3 8 L 0 42 L 3 8 Z" />
      <text x={0} y={-44} textAnchor="middle" className="rose-label">
        N
      </text>
      <text x={0} y={49} textAnchor="middle" className="rose-label mute">
        S
      </text>
    </svg>
  );
}

/** Atlas legend cartouche — explains the map glyphs.  Static
 *  content for now; if we add subscription colours / protocol
 *  shapes later, this becomes data-driven. */
function Legend(): JSX.Element {
  return (
    <div className="hud-legend">
      <div className="hud-legend-title mono">Legenda</div>
      <ul className="hud-legend-list mono">
        <li>
          <span className="lg-glyph lg-hex" /> hex · stations grouped by area
        </li>
        <li>
          <span className="lg-glyph lg-diamond" /> station · single host
        </li>
        <li>
          <span className="lg-glyph lg-diamond cur" /> active route
        </li>
        <li>
          <span className="lg-glyph lg-arc" /> bearing to current
        </li>
        <li>
          <span className="lg-glyph lg-vous" /> vous · you are here
        </li>
      </ul>
    </div>
  );
}
