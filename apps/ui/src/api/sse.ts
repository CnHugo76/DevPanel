/**
 * Server-Sent Events over fetch (so that an Authorization header can be sent; in the browser build
 * the session cookie is used instead). The parser follows the WHATWG event-stream format.
 */
import { authHeaders, ApiRequestError, readError } from './client';

export type SseHandler = (event: string, data: string) => void;

export class SseParser {
  private buf = '';
  private event = '';
  private data: string[] = [];
  private onEvent: SseHandler;

  constructor(onEvent: SseHandler) {
    this.onEvent = onEvent;
  }

  feed(chunk: string): void {
    this.buf += chunk;
    let pos = 0;
    const buf = this.buf;
    const n = buf.length;
    let cr = buf.indexOf('\r', pos);
    while (pos < n) {
      const lf = buf.indexOf('\n', pos);
      if (cr !== -1 && cr < pos) cr = buf.indexOf('\r', pos);
      let nl: number;
      let width = 1;
      if (cr !== -1 && (lf === -1 || cr < lf)) {
        if (cr + 1 >= n) break; // need more data to know whether \n follows
        nl = cr;
        if (buf.charCodeAt(cr + 1) === 10) width = 2;
      } else if (lf !== -1) {
        nl = lf;
      } else break;
      this.line(buf.slice(pos, nl));
      pos = nl + width;
    }
    this.buf = buf.slice(pos);
  }

  /** Call when the stream ends; an unterminated event is discarded per spec. */
  end(): void {
    this.buf = '';
    this.event = '';
    this.data = [];
  }

  private line(line: string): void {
    if (line === '') {
      if (this.data.length > 0) {
        const ev = this.event || 'message';
        const data = this.data.join('\n');
        this.event = '';
        this.data = [];
        this.onEvent(ev, data);
      } else {
        this.event = '';
      }
      return;
    }
    if (line.charCodeAt(0) === 58 /* : */) return; // comment
    const colon = line.indexOf(':');
    const field = colon === -1 ? line : line.slice(0, colon);
    let value = colon === -1 ? '' : line.slice(colon + 1);
    if (value.charCodeAt(0) === 32) value = value.slice(1);
    if (field === 'event') this.event = value;
    else if (field === 'data') this.data.push(value);
    // id / retry are not used: the contract has no resume for /events
  }
}

/**
 * Open an SSE stream and dispatch events until the server closes it (resolves) or it fails (rejects).
 * Aborting via `signal` rejects with an AbortError.
 */
export async function streamSse(url: string, onEvent: SseHandler, signal: AbortSignal): Promise<void> {
  let res: Response;
  try {
    res = await fetch(url, {
      headers: { Accept: 'text/event-stream', ...authHeaders() },
      credentials: 'same-origin',
      cache: 'no-store',
      signal,
    });
  } catch (e) {
    if (signal.aborted) throw e;
    throw new ApiRequestError(0, { code: 'DAEMON_UNREACHABLE', message: String((e as Error)?.message ?? e) });
  }
  if (!res.ok || !res.body) throw await readError(res);
  const parser = new SseParser(onEvent);
  const reader = res.body.pipeThrough(new TextDecoderStream()).getReader();
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (value) parser.feed(value);
    }
  } finally {
    parser.end();
    reader.releaseLock();
  }
}
