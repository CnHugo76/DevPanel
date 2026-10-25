import { memo, useEffect, useLayoutEffect, useRef } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import type { LogLine } from '@devpanel/contract';
import { markSegments, type AnsiStyle, type MarkedSegment, type Segment } from '../lib/ansi';
import { formatClockMs } from '../lib/format';
import { segmentsOf } from '../logs/text';

export const ROW_HEIGHT = 19.2; // 12px × 1.6

export interface Highlight {
  /** seq → sorted [start, end] ranges */
  ranges: Map<number, Array<readonly [number, number]>>;
  current: { seq: number; start: number } | null;
}

export interface LogViewHandle {
  scrollToSeq(seq: number): void;
  scrollToEnd(): void;
}

interface Props {
  lines: LogLine[];
  version: number;
  wrap: boolean;
  follow: boolean;
  highlight: Highlight;
  /** user scrolled away from the bottom */
  onLeaveBottom: () => void;
  /** user scrolled back to the bottom */
  onReachBottom: () => void;
  onNearTop: () => void;
  handleRef: React.MutableRefObject<LogViewHandle | null>;
}

function styleOf(st: AnsiStyle | null): { className?: string; style?: React.CSSProperties } {
  if (!st) return {};
  const cls: string[] = [];
  if (st.bold) cls.push('a-b');
  if (st.dim) cls.push('a-d');
  if (st.italic) cls.push('a-i');
  if (st.underline) cls.push('a-u');
  if (st.strike) cls.push('a-s');
  let color = st.fg;
  let bg = st.bg;
  if (st.inverse) {
    color = st.bg ?? 'var(--log-bg)';
    bg = st.fg ?? 'var(--text)';
  }
  const style: React.CSSProperties = {};
  if (color) style.color = color;
  if (bg) style.backgroundColor = bg;
  return { className: cls.length ? cls.join(' ') : undefined, style: color || bg ? style : undefined };
}

function renderSeg(seg: Segment | MarkedSegment, i: number): React.ReactNode {
  const mark = 'mark' in seg ? seg.mark : 0;
  const inner = mark ? <mark className={mark === 2 ? 'cur' : undefined}>{seg.text}</mark> : seg.text;
  if (!seg.style) return mark ? <span key={i}>{inner}</span> : <span key={i}>{seg.text}</span>;
  const { className, style } = styleOf(seg.style);
  return (
    <span key={i} className={className} style={style}>
      {inner}
    </span>
  );
}

const LineContent = memo(function LineContent({
  line,
  ranges,
  curStart,
}: {
  line: LogLine;
  ranges: Array<readonly [number, number]> | undefined;
  curStart: number;
}) {
  const segs = segmentsOf(line);
  const parts = ranges ? markSegments(segs, ranges.map(([s, e]) => [s, e, s === curStart] as const)) : segs;
  return <>{parts.map(renderSeg)}</>;
});

export function LogView(props: Props) {
  const { lines, version, wrap, follow, highlight } = props;
  const parentRef = useRef<HTMLDivElement>(null);
  const userIntent = useRef(0);
  const lastTop = useRef(0);
  const cbs = useRef(props);
  cbs.current = props;

  const virtualizer = useVirtualizer({
    count: lines.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => ROW_HEIGHT,
    overscan: 24,
    getItemKey: (i) => lines[i]?.seq ?? i,
    anchorTo: 'end',
    followOnAppend: follow,
    scrollEndThreshold: 12,
    paddingStart: 6,
    paddingEnd: 6,
  });

  props.handleRef.current = {
    scrollToSeq(seq: number) {
      let lo = 0;
      let hi = lines.length;
      while (lo < hi) {
        const mid = (lo + hi) >> 1;
        if (lines[mid]!.seq < seq) lo = mid + 1;
        else hi = mid;
      }
      if (lo < lines.length) virtualizer.scrollToIndex(lo, { align: 'center' });
    },
    scrollToEnd() {
      if (lines.length) virtualizer.scrollToIndex(lines.length - 1, { align: 'end' });
    },
  };

  // wrap toggles row heights → remeasure
  useEffect(() => {
    virtualizer.measure();
  }, [wrap, virtualizer]);

  // keep pinned to the bottom while following; totalSize changes once wrapped rows are
  // measured, so re-pin then too or the first paint is left scrolled past the last row
  const totalSize = virtualizer.getTotalSize();
  useLayoutEffect(() => {
    if (follow && lines.length) virtualizer.scrollToIndex(lines.length - 1, { align: 'end' });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [follow, version, wrap, totalSize]);

  const markIntent = () => {
    userIntent.current = Date.now();
  };
  const onScroll = () => {
    const el = parentRef.current;
    if (!el) return;
    const top = el.scrollTop;
    const atBottom = el.scrollHeight - top - el.clientHeight < 12;
    const userDriven = Date.now() - userIntent.current < 800;
    if (userDriven) {
      if (top < lastTop.current - 1 && !atBottom) cbs.current.onLeaveBottom();
      else if (atBottom) cbs.current.onReachBottom();
    }
    if (top < 400) cbs.current.onNearTop();
    lastTop.current = top;
  };

  const items = virtualizer.getVirtualItems();
  const cur = highlight.current;
  return (
    <div
      className={`lbody${wrap ? '' : ' nowrap'}`}
      ref={parentRef}
      onScroll={onScroll}
      onWheel={markIntent}
      onPointerDown={markIntent}
      onTouchMove={markIntent}
      onKeyDown={markIntent}
      tabIndex={0}
      aria-label="日志"
    >
      <div className="lrows" style={{ height: virtualizer.getTotalSize() }}>
        {items.map((it) => {
          const line = lines[it.index];
          if (!line) return null;
          const ranges = highlight.ranges.get(line.seq);
          return (
            <div
              key={it.key}
              data-index={it.index}
              ref={wrap ? virtualizer.measureElement : undefined}
              className={`ln ${line.stream}`}
              style={{ transform: `translateY(${it.start}px)`, height: wrap ? undefined : ROW_HEIGHT }}
            >
              <span className="ts">{formatClockMs(line.ts)}</span>
              <LineContent line={line} ranges={ranges} curStart={cur && cur.seq === line.seq ? cur.start : -1} />
              {line.partial && (
                <span className="cont" title="超长行已被拆分，下一行接续">
                  {' '}
                  ↩
                </span>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
