/**
 * Minimal ANSI parser for log lines.
 * - Only SGR (`ESC [ … m`) is interpreted: colors (16 / 256 / truecolor), bold, dim, italic, underline, inverse, strike.
 * - Every other escape / control sequence (cursor moves, OSC titles & hyperlinks, DCS, C0 controls except TAB) is dropped.
 * - Output is plain text segments; callers render them as text nodes, never as HTML.
 */

export interface AnsiStyle {
  /** CSS color value, e.g. "var(--ansi-2)" or "rgb(1,2,3)". */
  fg?: string;
  bg?: string;
  bold?: boolean;
  dim?: boolean;
  italic?: boolean;
  underline?: boolean;
  inverse?: boolean;
  strike?: boolean;
}

export interface Segment {
  text: string;
  style: AnsiStyle | null;
}

const ESC = 0x1b;
const BEL = 0x07;

function paletteColor(n: number): string {
  if (n < 16) return `var(--ansi-${n})`;
  if (n < 232) {
    const i = n - 16;
    const lv = [0, 95, 135, 175, 215, 255];
    return `rgb(${lv[Math.floor(i / 36) % 6]},${lv[Math.floor(i / 6) % 6]},${lv[i % 6]})`;
  }
  const g = 8 + (n - 232) * 10;
  return `rgb(${g},${g},${g})`;
}

function clampByte(v: number | undefined): number {
  return Math.max(0, Math.min(255, Math.floor(v ?? 0)));
}

/** Apply an SGR parameter string ("1;32", "38;5;208", "38:2::10:20:30", "") to a style. */
export function applySgr(prev: AnsiStyle, params: string): AnsiStyle {
  const style: AnsiStyle = { ...prev };
  const codes = params === '' ? [0] : params.split(/[;:]/).map((p) => (p === '' ? 0 : Number(p)));
  for (let i = 0; i < codes.length; i++) {
    const c = codes[i]!;
    if (c === 0) {
      for (const k of Object.keys(style) as (keyof AnsiStyle)[]) delete style[k];
    } else if (c === 1) style.bold = true;
    else if (c === 2) style.dim = true;
    else if (c === 3) style.italic = true;
    else if (c === 4 || c === 21) style.underline = true;
    else if (c === 7) style.inverse = true;
    else if (c === 9) style.strike = true;
    else if (c === 22) {
      delete style.bold;
      delete style.dim;
    } else if (c === 23) delete style.italic;
    else if (c === 24) delete style.underline;
    else if (c === 27) delete style.inverse;
    else if (c === 29) delete style.strike;
    else if (c >= 30 && c <= 37) style.fg = paletteColor(c - 30);
    else if (c === 39) delete style.fg;
    else if (c >= 40 && c <= 47) style.bg = paletteColor(c - 40);
    else if (c === 49) delete style.bg;
    else if (c >= 90 && c <= 97) style.fg = paletteColor(c - 90 + 8);
    else if (c >= 100 && c <= 107) style.bg = paletteColor(c - 100 + 8);
    else if (c === 38 || c === 48) {
      const mode = codes[i + 1];
      let color: string | null = null;
      if (mode === 5) {
        color = paletteColor(clampByte(codes[i + 2]));
        i += 2;
      } else if (mode === 2) {
        // Both "38;2;r;g;b" and the colon form "38:2::r:g:b" (empty colour-space id) occur in the wild.
        let j = i + 2;
        if (params.includes('::') && codes[j] === 0 && codes.length - j >= 4) j++;
        color = `rgb(${clampByte(codes[j])},${clampByte(codes[j + 1])},${clampByte(codes[j + 2])})`;
        i = j + 2;
      } else {
        i = codes.length; // malformed: ignore rest
      }
      if (color) {
        if (c === 38) style.fg = color;
        else style.bg = color;
      }
    }
    // anything else (blink, fonts, …) is ignored
  }
  return style;
}

function isEmpty(s: AnsiStyle): boolean {
  for (const _ in s) return false;
  return true;
}

/** Index just past a string terminated by BEL or ESC \ (OSC/DCS/APC/PM/SOS). */
function skipString(input: string, from: number): number {
  for (let j = from; j < input.length; j++) {
    const c = input.charCodeAt(j);
    if (c === BEL) return j + 1;
    if (c === ESC && input[j + 1] === '\\') return j + 2;
  }
  return input.length;
}

export function parseAnsi(input: string): Segment[] {
  const out: Segment[] = [];
  let style: AnsiStyle = {};
  let buf = '';
  let runStart = 0;
  const n = input.length;
  const flushRun = (end: number) => {
    if (end > runStart) buf += input.slice(runStart, end);
  };
  const pushSeg = () => {
    if (buf) {
      out.push({ text: buf, style: isEmpty(style) ? null : style });
      buf = '';
    }
  };
  let i = 0;
  while (i < n) {
    const ch = input.charCodeAt(i);
    if (ch >= 0x20 && ch !== 0x7f && !(ch >= 0x80 && ch <= 0x9f)) {
      i++;
      continue;
    }
    flushRun(i);
    if (ch === 0x09) {
      buf += '\t';
      i++;
    } else if (ch === ESC) {
      const next = input[i + 1];
      if (next === '[') {
        let j = i + 2;
        while (j < n) {
          const c = input.charCodeAt(j);
          if (c >= 0x40 && c <= 0x7e) break;
          j++;
        }
        if (j >= n) {
          i = n; // unterminated CSI: drop the rest
        } else {
          if (input[j] === 'm') {
            const params = input.slice(i + 2, j);
            if (/^[\d;:]*$/.test(params)) {
              const nextStyle = applySgr(style, params);
              pushSeg();
              style = nextStyle;
            }
          }
          i = j + 1;
        }
      } else if (next === ']' || next === 'P' || next === '^' || next === '_' || next === 'X') {
        i = skipString(input, i + 2);
      } else if (next !== undefined && '()*+-./#%'.includes(next)) {
        i += 3; // charset designation etc.
      } else {
        i += next === undefined ? 1 : 2;
      }
    } else if (ch === 0x9b) {
      // C1 CSI: skip to final byte
      let j = i + 1;
      while (j < n && !(input.charCodeAt(j) >= 0x40 && input.charCodeAt(j) <= 0x7e)) j++;
      i = j + 1;
    } else if (ch === 0x9d) {
      i = skipString(input, i + 1);
    } else {
      i++; // other C0/C1 controls (incl. \r, \b) are dropped
    }
    runStart = i;
  }
  flushRun(n);
  pushSeg();
  return out;
}

/** Text without any escape / control sequences. */
export function stripAnsi(input: string): string {
  // fast path: nothing to strip
  // eslint-disable-next-line no-control-regex
  if (!/[\x00-\x08\x0a-\x1f\x7f-\x9f]/.test(input)) return input;
  return parseAnsi(input)
    .map((s) => s.text)
    .join('');
}

export interface MarkedSegment extends Segment {
  /** 0 = no match, 1 = match, 2 = current match */
  mark: 0 | 1 | 2;
}

/**
 * Split segments at match ranges (offsets in the plain text).
 * ranges must be sorted and non-overlapping: [start, end, isCurrent].
 */
export function markSegments(segments: Segment[], ranges: ReadonlyArray<readonly [number, number, boolean]>): MarkedSegment[] {
  if (ranges.length === 0) return segments.map((s) => ({ ...s, mark: 0 }));
  const out: MarkedSegment[] = [];
  let pos = 0;
  let r = 0;
  for (const seg of segments) {
    const segStart = pos;
    const segEnd = pos + seg.text.length;
    let cur = segStart;
    while (cur < segEnd) {
      while (r < ranges.length && ranges[r]![1] <= cur) r++;
      const range = ranges[r];
      if (!range || range[0] >= segEnd) {
        out.push({ text: seg.text.slice(cur - segStart), style: seg.style, mark: 0 });
        cur = segEnd;
        break;
      }
      if (range[0] > cur) {
        out.push({ text: seg.text.slice(cur - segStart, range[0] - segStart), style: seg.style, mark: 0 });
        cur = range[0];
      }
      const end = Math.min(range[1], segEnd);
      out.push({ text: seg.text.slice(cur - segStart, end - segStart), style: seg.style, mark: range[2] ? 2 : 1 });
      cur = end;
    }
    pos = segEnd;
  }
  return out;
}
