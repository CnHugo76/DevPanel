import { describe, expect, it } from 'vitest';
import { applySgr, markSegments, parseAnsi, stripAnsi } from '../src/lib/ansi';

describe('parseAnsi', () => {
  it('returns plain text unchanged', () => {
    expect(parseAnsi('hello world')).toEqual([{ text: 'hello world', style: null }]);
  });

  it('applies basic SGR colors and resets', () => {
    const segs = parseAnsi('\x1b[32mINFO\x1b[0m done');
    expect(segs).toEqual([
      { text: 'INFO', style: { fg: 'var(--ansi-2)' } },
      { text: ' done', style: null },
    ]);
  });

  it('handles bold/dim/italic/underline and partial resets', () => {
    const segs = parseAnsi('\x1b[1;4mA\x1b[22mB\x1b[24mC');
    expect(segs[0]).toEqual({ text: 'A', style: { bold: true, underline: true } });
    expect(segs[1]).toEqual({ text: 'B', style: { underline: true } });
    expect(segs[2]).toEqual({ text: 'C', style: null });
  });

  it('supports bright, 256 and truecolor', () => {
    expect(parseAnsi('\x1b[91mx')[0]!.style).toEqual({ fg: 'var(--ansi-9)' });
    expect(parseAnsi('\x1b[38;5;196mx')[0]!.style).toEqual({ fg: 'rgb(255,0,0)' });
    expect(parseAnsi('\x1b[38;5;244mx')[0]!.style).toEqual({ fg: 'rgb(128,128,128)' });
    expect(parseAnsi('\x1b[48;2;10;20;30mx')[0]!.style).toEqual({ bg: 'rgb(10,20,30)' });
    expect(parseAnsi('\x1b[38:2::1:2:3mx')[0]!.style).toEqual({ fg: 'rgb(1,2,3)' });
  });

  it('treats an empty SGR as reset', () => {
    expect(parseAnsi('\x1b[31mred\x1b[mplain')).toEqual([
      { text: 'red', style: { fg: 'var(--ansi-1)' } },
      { text: 'plain', style: null },
    ]);
  });

  it('drops non-SGR control sequences and control characters', () => {
    expect(stripAnsi('\x1b[2K\x1b[1Gprogress\r 50%\x07')).toBe('progress 50%');
    expect(stripAnsi('\x1b]0;window title\x07after')).toBe('after');
    expect(stripAnsi('\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\')).toBe('link');
    expect(stripAnsi('a\x1b(Bb')).toBe('ab');
    expect(stripAnsi('tab\tkept')).toBe('tab\tkept');
  });

  it('never interprets markup', () => {
    expect(stripAnsi('<script>alert(1)</script>')).toBe('<script>alert(1)</script>');
  });

  it('drops an unterminated CSI', () => {
    expect(stripAnsi('ok\x1b[31')).toBe('ok');
  });

  it('applySgr ignores unknown codes', () => {
    expect(applySgr({ bold: true }, '5;53')).toEqual({ bold: true });
  });
});

describe('markSegments', () => {
  it('splits styled segments at match ranges', () => {
    const segs = parseAnsi('\x1b[32mINFO\x1b[0m GET /api/orders');
    const marked = markSegments(segs, [
      [2, 6, false],
      [9, 12, true],
    ]);
    expect(marked.map((m) => [m.text, m.mark])).toEqual([
      ['IN', 0],
      ['FO', 1],
      [' G', 1],
      ['ET ', 0],
      ['/ap', 2],
      ['i/orders', 0],
    ]);
    expect(marked[1]!.style).toEqual({ fg: 'var(--ansi-2)' });
  });

  it('returns unmarked copies without ranges', () => {
    expect(markSegments([{ text: 'x', style: null }], [])).toEqual([{ text: 'x', style: null, mark: 0 }]);
  });
});
