/**
 * numerals — shared roman-numeral helpers with a sane cap.
 *
 * Atlas-style UI uses I/II/III for short ordered lists (Routing
 * register, Tray "i—iii of x", Pool chips).  Past ~XII the glyphs
 * stop being decorative and start being unreadable
 * ("CCCCCCCCCLXXXVII").  Cap at XII by default and render arabic
 * past that — "12", "48", "387" — so the numbers stay legible at
 * any list length.
 */
const SYMS_UPPER: ReadonlyArray<readonly [number, string]> = [
  [10, "X"],
  [9, "IX"],
  [5, "V"],
  [4, "IV"],
  [1, "I"],
];

const SYMS_LOWER: ReadonlyArray<readonly [number, string]> = [
  [10, "x"],
  [9, "ix"],
  [5, "v"],
  [4, "iv"],
  [1, "i"],
];

function build(n: number, syms: ReadonlyArray<readonly [number, string]>): string {
  let out = "";
  for (const [v, sym] of syms) {
    while (n >= v) {
      out += sym;
      n -= v;
    }
  }
  return out;
}

/** Default cap: anything past XII becomes arabic. */
const DEFAULT_CAP = 12;

export function roman(n: number, cap: number = DEFAULT_CAP): string {
  if (!Number.isFinite(n) || n <= 0) return String(n | 0);
  if (n > cap) return String(n | 0);
  return build(n | 0, SYMS_UPPER);
}

export function romanLower(n: number, cap: number = DEFAULT_CAP): string {
  if (!Number.isFinite(n) || n <= 0) return String(n | 0);
  if (n > cap) return String(n | 0);
  return build(n | 0, SYMS_LOWER);
}
