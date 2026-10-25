/**
 * Shell-style argv splitting for the single-line command input.
 * Rules (POSIX sh subset): whitespace separates words; '…' is literal; "…" allows \" \\ \$ \` escapes;
 * a backslash outside quotes escapes the next character. No expansion, globbing or operators.
 */

export interface SplitResult {
  argv: string[];
  error: string | null;
}

export function splitArgv(input: string): SplitResult {
  const argv: string[] = [];
  let cur = '';
  let inWord = false;
  let quote: '"' | "'" | null = null;
  for (let i = 0; i < input.length; i++) {
    const ch = input[i]!;
    if (quote === "'") {
      if (ch === "'") quote = null;
      else cur += ch;
      continue;
    }
    if (quote === '"') {
      if (ch === '"') quote = null;
      else if (ch === '\\' && i + 1 < input.length && '"\\$`\n'.includes(input[i + 1]!)) {
        const nx = input[++i]!;
        if (nx !== '\n') cur += nx;
      } else cur += ch;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      inWord = true;
      continue;
    }
    if (ch === '\\') {
      if (i + 1 < input.length) {
        const nx = input[++i]!;
        if (nx !== '\n') {
          cur += nx;
          inWord = true;
        }
      } else {
        cur += '\\';
        inWord = true;
      }
      continue;
    }
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') {
      if (inWord) {
        argv.push(cur);
        cur = '';
        inWord = false;
      }
      continue;
    }
    cur += ch;
    inWord = true;
  }
  if (quote) return { argv: inWord ? [...argv, cur] : argv, error: quote === '"' ? '双引号未闭合' : '单引号未闭合' };
  if (inWord) argv.push(cur);
  return { argv, error: null };
}

const SAFE = /^[A-Za-z0-9_\-+=.,/:@%^]+$/;

/** Quote one argument so that splitArgv(joinArgv(x)) round-trips. */
export function quoteArg(arg: string): string {
  if (arg === '') return "''";
  if (SAFE.test(arg)) return arg;
  return `'${arg.replace(/'/g, `'\\''`)}'`;
}

export function joinArgv(argv: readonly string[]): string {
  return argv.map(quoteArg).join(' ');
}

export const SHELL_PROGRAM = '/bin/zsh';
export const SHELL_FLAG = '-lc';
const SHELLS = new Set(['/bin/zsh', '/bin/bash', '/bin/sh', 'zsh', 'bash', 'sh']);

/** ["/bin/zsh", "-lc", "<text>"] (or bash/sh, -c) → the text; otherwise null. */
export function shellText(command: readonly string[]): { shell: string; flag: string; text: string } | null {
  if (command.length === 3 && SHELLS.has(command[0]!) && (command[1] === '-lc' || command[1] === '-c')) {
    return { shell: command[0]!, flag: command[1]!, text: command[2]! };
  }
  return null;
}

/**
 * Detect commands that background / detach themselves (cannot be managed).
 * Scans the raw text with quote awareness. Returns the offending token or null.
 */
export function detectBackground(text: string): string | null {
  // tokenise into words and control operators, honouring quotes
  const tokens: Array<{ t: string; op: boolean }> = [];
  let cur = '';
  let quote: string | null = null;
  const push = () => {
    if (cur) tokens.push({ t: cur, op: false });
    cur = '';
  };
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]!;
    if (quote) {
      if (ch === quote) quote = null;
      else cur += ch;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }
    if (ch === '\\') {
      cur += text[i + 1] ?? '';
      i++;
      continue;
    }
    if (/\s/.test(ch)) {
      push();
      continue;
    }
    if (ch === '&' || ch === '|' || ch === ';') {
      const two = text.slice(i, i + 2);
      if (two === '&&' || two === '||') {
        push();
        tokens.push({ t: two, op: true });
        i++;
        continue;
      }
      // redirections like 2>&1, &>file, >&2 are not backgrounding
      if (ch === '&' && (text[i - 1] === '>' || text[i - 1] === '<' || text[i + 1] === '>')) {
        cur += ch;
        continue;
      }
      push();
      tokens.push({ t: ch, op: true });
      continue;
    }
    cur += ch;
  }
  push();

  if (tokens.some((x) => x.op && x.t === '&')) return '&';
  // command words: first token and tokens after an operator
  for (let i = 0; i < tokens.length; i++) {
    const tk = tokens[i]!;
    if (tk.op) continue;
    const isCmd = i === 0 || tokens[i - 1]!.op;
    if (!isCmd) continue;
    const name = tk.t.split('/').pop()!;
    if (name === 'nohup' || name === 'disown' || name === 'setsid' || name === 'daemonize') return name;
    if (name === 'docker' || name === 'docker-compose' || name === 'podman') {
      const rest: string[] = [];
      for (let j = i + 1; j < tokens.length && !tokens[j]!.op; j++) rest.push(tokens[j]!.t);
      // -d, --detach, or combined short flags such as -itd / -dit
      if (rest.some((r) => r === '--detach' || (/^-[dit]+$/.test(r) && r.includes('d')))) return '-d';
    }
  }
  return null;
}
