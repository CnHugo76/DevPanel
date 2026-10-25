/**
 * Simulated process behaviour: realistic log output for a few common stacks
 * (Spring Boot via Maven, Vite dev server, Python uvicorn), plus resource baselines.
 */
import type { ListeningPort, LogStream } from '@devpanel/contract';
import { clockTime, localIsoWithOffset, pick, rand, randInt } from './util.ts';

export type ProfileKind = 'spring' | 'vite' | 'next' | 'uvicorn' | 'docs' | 'generic';

export interface SimProfile {
  kind: ProfileKind;
  /** Ignores SIGTERM (only SIGKILL ends it). */
  hangOnStop?: boolean;
  /** Ends on its own after this long (ms since spawn). */
  exitAfterMs?: number;
  exitCode?: number;
  /** Startup fails with "port already in use" then exits 1. */
  portConflict?: boolean;
  /** Approximate CPU% / RSS baselines. */
  cpu?: number;
  rssMiB?: number;
}

export interface Emit {
  stream: LogStream;
  text: string;
}

export interface SimCtx {
  pid: number;
  childPid: number;
  appName: string;
  port: number;
  cwd: string;
  /** Bind address the simulated server listens on. */
  host: string;
  /** Spring profile from the substituted command / env, null = none set. */
  springProfile: string | null;
  /** uvicorn --reload / UVICORN_RELOAD=true. */
  reload: boolean;
}

const ESC = '\x1b[';
const c = {
  reset: `${ESC}0m`,
  bold: `${ESC}1m`,
  dim: `${ESC}2m`,
  nobold: `${ESC}22m`,
  red: `${ESC}31m`,
  green: `${ESC}32m`,
  yellow: `${ESC}33m`,
  blue: `${ESC}34m`,
  magenta: `${ESC}35m`,
  cyan: `${ESC}36m`,
  fg: `${ESC}39m`,
  brightBlack: `${ESC}90m`,
};

export function inferProfile(command: string[]): SimProfile {
  const joined = command.join(' ');
  if (/mvn|gradle|java|spring/.test(joined)) return { kind: 'spring' };
  if (/uvicorn|python|gunicorn|fastapi|\buv\b/.test(joined)) return { kind: 'uvicorn' };
  if (/vitepress|docs/.test(joined)) return { kind: 'docs' };
  if (/\bnext\b/.test(joined)) return { kind: 'next' };
  if (/vite|pnpm|npm|yarn|node|next/.test(joined)) return { kind: 'vite' };
  return { kind: 'generic' };
}

export function processesFor(kind: ProfileKind): string[] {
  switch (kind) {
    case 'spring':
      return ['sh', 'java', 'java', 'java'];
    case 'vite':
    case 'docs':
      return ['node', 'node', 'esbuild'];
    case 'next':
      return ['node', 'node'];
    case 'uvicorn':
      return ['uv', 'python3'];
    default:
      return ['sh'];
  }
}

export function baseline(p: SimProfile): { cpu: number; rssMiB: number } {
  if (p.cpu !== undefined && p.rssMiB !== undefined) return { cpu: p.cpu, rssMiB: p.rssMiB };
  switch (p.kind) {
    case 'spring':
      return { cpu: p.cpu ?? 128, rssMiB: p.rssMiB ?? 1045 };
    case 'vite':
      return { cpu: p.cpu ?? 4.4, rssMiB: p.rssMiB ?? 190 };
    case 'next':
      return { cpu: p.cpu ?? 6.2, rssMiB: p.rssMiB ?? 430 };
    case 'docs':
      return { cpu: p.cpu ?? 2.1, rssMiB: p.rssMiB ?? 150 };
    case 'uvicorn':
      return { cpu: p.cpu ?? 1.6, rssMiB: p.rssMiB ?? 96 };
    default:
      return { cpu: p.cpu ?? 0.4, rssMiB: p.rssMiB ?? 12 };
  }
}

// ───────────── Spring Boot ─────────────

function springLine(t: number, level: 'INFO' | 'WARN' | 'ERROR' | 'DEBUG', pid: number, thread: string, logger: string, msg: string): string {
  const lc = level === 'INFO' ? c.green : level === 'WARN' ? c.yellow : level === 'ERROR' ? c.red : c.blue;
  return `${c.dim}${localIsoWithOffset(t)}${c.reset}  ${lc}${level.padStart(5)}${c.reset} ${c.magenta}${pid}${c.reset} ${c.dim}---${c.reset} ${c.dim}[${thread.padStart(15)}]${c.reset} ${c.cyan}${logger.padEnd(40).slice(0, 40)}${c.reset} ${c.dim}:${c.reset} ${msg}`;
}

const JAVA_STACK = [
  'java.net.ConnectException: Connection refused',
  '\tat java.base/sun.nio.ch.Net.pollConnect(Native Method)',
  '\tat java.base/sun.nio.ch.Net.pollConnectNow(Net.java:682)',
  '\tat java.base/sun.nio.ch.NioSocketImpl.timedFinishConnect(NioSocketImpl.java:554)',
  '\tat java.base/sun.nio.ch.NioSocketImpl.connect(NioSocketImpl.java:602)',
  '\tat java.base/java.net.SocksSocketImpl.connect(SocksSocketImpl.java:327)',
  '\tat java.base/java.net.Socket.connect(Socket.java:751)',
  '\tat org.postgresql.core.PGStream.createSocket(PGStream.java:243)',
  '\tat org.postgresql.core.PGStream.<init>(PGStream.java:98)',
  '\tat org.postgresql.core.v3.ConnectionFactoryImpl.tryConnect(ConnectionFactoryImpl.java:132)',
  '\t... 47 common frames omitted',
];

const ORDER_PATHS = ['/api/orders?page=1', '/api/orders/1832', '/api/orders/1833/items', '/api/customers/77', '/api/orders?status=PAID', '/actuator/info'];

function springStartup(ctx: SimCtx, t: number): Emit[] {
  const app = ctx.appName;
  const out = (text: string): Emit => ({ stream: 'out', text });
  const err = (text: string): Emit => ({ stream: 'err', text });
  const pid = ctx.childPid;
  return [
    out(`${c.bold}[INFO]${c.reset} Scanning for projects...`),
    out(`${c.bold}[INFO]${c.reset} `),
    out(`${c.bold}[INFO]${c.reset} ${c.cyan}------------------< ${c.reset}${c.bold}com.example:${app}${c.reset}${c.cyan} >------------------${c.reset}`),
    out(`${c.bold}[INFO]${c.reset} ${c.bold}Building ${app} 0.4.2-SNAPSHOT${c.reset}`),
    out(`${c.bold}[INFO]${c.reset}   from pom.xml`),
    out(`${c.bold}[INFO]${c.reset} ${c.cyan}--------------------------------[ jar ]---------------------------------${c.reset}`),
    out(`${c.bold}[INFO]${c.reset} `),
    out(`${c.bold}[INFO]${c.reset} ${c.green}>>> ${c.bold}spring-boot:3.4.1:run${c.reset} ${c.bold}(default-cli)${c.reset} > ${c.bold}test-compile${c.reset} @ ${app} ${c.green}>>>${c.reset}`),
    out(`${c.bold}[INFO]${c.reset} ${c.green}--- ${c.bold}resources:3.3.1:resources${c.reset} ${c.bold}(default-resources)${c.reset} @ ${app} ${c.green}---${c.reset}`),
    out(`${c.bold}[INFO]${c.reset} Copying 3 resources from src/main/resources to target/classes`),
    out(`${c.bold}[INFO]${c.reset} ${c.green}--- ${c.bold}compiler:3.13.0:compile${c.reset} ${c.bold}(default-compile)${c.reset} @ ${app} ${c.green}---${c.reset}`),
    out(`${c.bold}[INFO]${c.reset} Nothing to compile - all classes are up to date.`),
    out(`${c.bold}[INFO]${c.reset} ${c.green}--- ${c.bold}spring-boot:3.4.1:run${c.reset} ${c.bold}(default-cli)${c.reset} @ ${app} ${c.green}---${c.reset}`),
    out(`${c.bold}[INFO]${c.reset} Attaching agents: []`),
    out(''),
    out('  .   ____          _            __ _ _'),
    out(" /\\\\ / ___'_ __ _ _(_)_ __  __ _ \\ \\ \\ \\"),
    out("( ( )\\___ | '_ | '_| | '_ \\/ _` | \\ \\ \\ \\"),
    out(" \\\\/  ___)| |_)| | | | | || (_| |  ) ) ) )"),
    out("  '  |____| .__|_| |_|_| |_\\__, | / / / /"),
    out(' =========|_|==============|___/=/_/_/_/'),
    out(''),
    out(`${c.dim} :: Spring Boot :: ${c.reset}               (v3.4.1)`),
    out(''),
    out(springLine(t, 'INFO', pid, 'main', 'c.e.order.OrderApplication', `Starting OrderApplication using Java 21.0.4 with PID ${pid} (${ctx.cwd}/target/classes started by hugo in ${ctx.cwd})`)),
    out(
      ctx.springProfile
        ? springLine(t + 12, 'INFO', pid, 'main', 'c.e.order.OrderApplication', `The following 1 profile is active: "${ctx.springProfile}"`)
        : springLine(t + 12, 'INFO', pid, 'main', 'c.e.order.OrderApplication', 'No active profile set, falling back to 1 default profile: "default"'),
    ),
    out(springLine(t + 900, 'INFO', pid, 'main', '.s.d.r.c.RepositoryConfigurationDelegate', 'Bootstrapping Spring Data JPA repositories in DEFAULT mode.')),
    out(springLine(t + 1100, 'INFO', pid, 'main', '.s.d.r.c.RepositoryConfigurationDelegate', 'Finished Spring Data repository scanning in 87 ms. Found 6 JPA repository interfaces.')),
    out(springLine(t + 1700, 'INFO', pid, 'main', 'o.s.b.w.embedded.tomcat.TomcatWebServer', `Tomcat initialized with port ${ctx.port} (http)`)),
    out(springLine(t + 1710, 'INFO', pid, 'main', 'o.apache.catalina.core.StandardService', 'Starting service [Tomcat]')),
    out(springLine(t + 1712, 'INFO', pid, 'main', 'o.apache.catalina.core.StandardEngine', 'Starting Servlet engine: [Apache Tomcat/10.1.34]')),
    out(springLine(t + 1800, 'INFO', pid, 'main', 'o.a.c.c.C.[Tomcat].[localhost].[/]', 'Initializing Spring embedded WebApplicationContext')),
    out(springLine(t + 2400, 'INFO', pid, 'main', 'com.zaxxer.hikari.HikariDataSource', 'HikariPool-1 - Starting...')),
    err(springLine(t + 3500, 'WARN', pid, 'main', 'o.h.e.j.e.i.JdbcEnvironmentInitiator', 'HHH000342: Could not obtain connection to query metadata')),
    ...JAVA_STACK.map(err),
    out(springLine(t + 4200, 'INFO', pid, 'main', 'com.zaxxer.hikari.pool.HikariPool', 'HikariPool-1 - Added connection org.postgresql.jdbc.PgConnection@5d2a4eed')),
    out(springLine(t + 4210, 'INFO', pid, 'main', 'com.zaxxer.hikari.HikariDataSource', 'HikariPool-1 - Start completed.')),
    out(springLine(t + 5100, 'INFO', pid, 'main', 'o.s.b.a.e.web.EndpointLinksResolver', 'Exposing 2 endpoints beneath base path \'/actuator\'')),
    out(springLine(t + 5100, 'INFO', pid, 'restartedMain', 'o.s.b.d.a.OptionalLiveReloadServer', `LiveReload server is running on port ${SPRING_LIVERELOAD_PORT}`)),
    out(springLine(t + 5600, 'INFO', pid, 'main', 'o.s.b.w.embedded.tomcat.TomcatWebServer', `Tomcat started on port ${ctx.port} (http) with context path '/'`)),
    out(springLine(t + 5620, 'INFO', pid, 'main', 'c.e.order.OrderApplication', 'Started OrderApplication in 5.62 seconds (process running for 6.4)')),
  ];
}

function springTick(ctx: SimCtx, t: number): Emit[] {
  const pid = ctx.childPid;
  const r = Math.random();
  const thread = `nio-${ctx.port}-exec-${randInt(1, 10)}`;
  if (r < 0.04) {
    return [
      { stream: 'err', text: springLine(t, 'ERROR', pid, thread, 'o.a.c.c.C.[.[.[/].[dispatcherServlet]', 'Servlet.service() for servlet [dispatcherServlet] threw exception') },
      { stream: 'err', text: 'java.lang.IllegalStateException: Order 1834 is already settled' },
      { stream: 'err', text: '\tat com.example.order.service.OrderService.settle(OrderService.java:142)' },
      { stream: 'err', text: '\tat com.example.order.web.OrderController.settle(OrderController.java:88)' },
      { stream: 'err', text: '\tat java.base/jdk.internal.reflect.DirectMethodHandleAccessor.invoke(DirectMethodHandleAccessor.java:103)' },
      { stream: 'err', text: '\tat org.springframework.web.method.support.InvocableHandlerMethod.doInvoke(InvocableHandlerMethod.java:255)' },
      { stream: 'err', text: '\t... 52 common frames omitted' },
    ];
  }
  if (r < 0.08) {
    return [{ stream: 'err', text: springLine(t, 'WARN', pid, thread, 'o.s.web.servlet.PageNotFound', `No mapping for GET /favicon.ico`) }];
  }
  if (r < 0.1) {
    // a very long single line (serialized payload dump)
    const items = Array.from({ length: randInt(40, 120) }, (_, i) => ({ id: 1800 + i, sku: `SKU-${randInt(10000, 99999)}`, qty: randInt(1, 9), price: Number(rand(3, 400).toFixed(2)), note: 'lorem ipsum dolor sit amet' }));
    return [{ stream: 'out', text: springLine(t, 'DEBUG', pid, thread, 'c.e.order.web.OrderController', `Response body: ${JSON.stringify({ page: 1, size: items.length, items })}`) }];
  }
  const method = pick(['GET', 'GET', 'GET', 'POST', 'PUT']);
  const p = pick(ORDER_PATHS);
  const status = method === 'POST' ? 201 : pick([200, 200, 200, 200, 404]);
  return [{ stream: 'out', text: springLine(t, 'INFO', pid, thread, 'c.e.order.web.OrderController', `${method} ${p} ${status} ${randInt(2, 60)}ms`) }];
}

function springTerm(ctx: SimCtx, t: number): Emit[] {
  const pid = ctx.childPid;
  return [
    { stream: 'out', text: springLine(t, 'INFO', pid, 'ionShutdownHook', 'o.s.b.w.e.tomcat.GracefulShutdown', 'Commencing graceful shutdown. Waiting for active requests to complete') },
    { stream: 'out', text: springLine(t + 20, 'INFO', pid, 'tomcat-shutdown', 'o.s.b.w.e.tomcat.GracefulShutdown', 'Graceful shutdown complete') },
    { stream: 'out', text: springLine(t + 40, 'INFO', pid, 'ionShutdownHook', 'com.zaxxer.hikari.HikariDataSource', 'HikariPool-1 - Shutdown initiated...') },
    { stream: 'out', text: springLine(t + 60, 'INFO', pid, 'ionShutdownHook', 'com.zaxxer.hikari.HikariDataSource', 'HikariPool-1 - Shutdown completed.') },
  ];
}

export function springPortConflict(ctx: SimCtx, t: number): Emit[] {
  const pid = ctx.childPid;
  return [
    { stream: 'err', text: springLine(t, 'ERROR', pid, 'main', 'o.s.b.d.LoggingFailureAnalysisReporter', '') },
    { stream: 'err', text: '' },
    { stream: 'err', text: '***************************' },
    { stream: 'err', text: 'APPLICATION FAILED TO START' },
    { stream: 'err', text: '***************************' },
    { stream: 'err', text: '' },
    { stream: 'err', text: 'Description:' },
    { stream: 'err', text: '' },
    { stream: 'err', text: `Web server failed to start. Port ${ctx.port} was already in use.` },
    { stream: 'err', text: '' },
    { stream: 'err', text: 'Action:' },
    { stream: 'err', text: '' },
    { stream: 'err', text: `Identify and stop the process that's listening on port ${ctx.port} or configure this application to listen on another port.` },
    { stream: 'out', text: `${c.bold}[INFO]${c.reset} ${c.red}------------------------------------------------------------------------${c.reset}` },
    { stream: 'out', text: `${c.bold}[INFO]${c.reset} ${c.red}${c.bold}BUILD FAILURE${c.reset}` },
    { stream: 'err', text: `${c.bold}${c.red}[ERROR]${c.reset} Failed to execute goal org.springframework.boot:spring-boot-maven-plugin:3.4.1:run (default-cli) on project order-backend: Process terminated with exit code: 1 -> ${c.bold}[Help 1]${c.reset}` },
  ];
}

// ───────────── Vite ─────────────

const VITE_FILES = ['/src/pages/Users.tsx', '/src/pages/Orders.tsx', '/src/components/Table.tsx', '/src/App.tsx', '/src/styles/main.css', '/src/api/client.ts'];

function viteStartup(ctx: SimCtx): Emit[] {
  return [
    { stream: 'out', text: '' },
    { stream: 'out', text: `> ${ctx.appName}@0.3.0 dev ${ctx.cwd}` },
    { stream: 'out', text: '> vite' },
    { stream: 'out', text: '' },
    { stream: 'out', text: `${c.green}${c.bold}  VITE${c.nobold} v6.0.7${c.fg}  ${c.dim}ready in ${c.reset}${c.bold}${randInt(280, 900)}${c.nobold}${c.dim} ms${c.nobold}` },
    { stream: 'out', text: '' },
    { stream: 'out', text: `  ${c.green}➜${c.fg}  ${c.bold}Local${c.nobold}:   ${c.cyan}http://localhost:${c.bold}${ctx.port}${c.nobold}/${c.fg}` },
    { stream: 'out', text: `  ${c.green}➜${c.fg}  ${c.bold}Network${c.nobold}${c.dim}: use ${c.nobold}${c.bold}--host${c.nobold}${c.dim} to expose${c.nobold}` },
    { stream: 'out', text: `  ${c.green}➜${c.fg}  ${c.dim}press ${c.nobold}${c.bold}h + enter${c.nobold}${c.dim} to show help${c.nobold}` },
  ];
}

function viteTick(_ctx: SimCtx, t: number): Emit[] {
  const ts = `${c.dim}${clockTime(t)}${c.nobold}`;
  const tag = `${c.cyan}${c.bold}[vite]${c.nobold}${c.fg}`;
  const r = Math.random();
  if (r < 0.05) {
    const f = pick(VITE_FILES);
    return [
      { stream: 'err', text: `${ts} ${c.red}${c.bold}[vite]${c.nobold}${c.fg} ${c.red}Internal server error: ${ctx_err(f)}${c.fg}` },
      { stream: 'err', text: `  Plugin: ${c.magenta}vite:esbuild${c.fg}` },
      { stream: 'err', text: `  File: ${c.cyan}${f}:${randInt(10, 120)}:${randInt(2, 40)}${c.fg}` },
      { stream: 'err', text: `      at failureErrorWithLog (node_modules/esbuild/lib/main.js:1476:15)` },
      { stream: 'err', text: `      at node_modules/esbuild/lib/main.js:755:50` },
    ];
  }
  if (r < 0.15) return [{ stream: 'out', text: `${ts} ${tag} ${c.green}page reload ${c.fg}${c.dim}${pick(VITE_FILES)}${c.nobold}` }];
  return [{ stream: 'out', text: `${ts} ${tag} ${c.green}hmr update ${c.fg}${c.dim}${pick(VITE_FILES)}${c.nobold}` }];
}
function ctx_err(f: string): string {
  return `Transform failed with 1 error:\n${f}:42:17: ERROR: Expected ")" but found "}"`.split('\n')[0]!;
}

function viteTerm(): Emit[] {
  return [{ stream: 'err', text: ` ${c.red}ELIFECYCLE${c.fg}  Command failed.` }];
}

// ───────────── Next.js ─────────────

const NEXT_ROUTES = ['/orders', '/orders/[id]', '/customers', '/login', '/api/health'];

function nextStartup(ctx: SimCtx): Emit[] {
  return [
    { stream: 'out', text: '' },
    { stream: 'out', text: `> ${ctx.appName}-web@0.4.2 dev ${ctx.cwd}` },
    { stream: 'out', text: `> next dev -p ${ctx.port}` },
    { stream: 'out', text: '' },
    { stream: 'out', text: `   ${c.magenta}${c.bold}▲ Next.js 15.1.3${c.reset}` },
    { stream: 'out', text: `   - Local:        http://localhost:${ctx.port}` },
    { stream: 'out', text: `   - Network:      http://192.168.1.23:${ctx.port}` },
    { stream: 'out', text: '   - Environments: .env.local' },
    { stream: 'out', text: '' },
    { stream: 'out', text: ` ${c.green}✓${c.reset} Starting...` },
    { stream: 'out', text: ` ${c.green}✓${c.reset} Ready in ${randInt(1200, 2600)}ms` },
  ];
}

function nextTick(): Emit[] {
  const route = pick(NEXT_ROUTES);
  const r = Math.random();
  if (r < 0.04) {
    return [
      { stream: 'err', text: ` ${c.red}⨯${c.reset} TypeError: Cannot read properties of undefined (reading 'items')` },
      { stream: 'err', text: '    at OrdersTable (./src/app/orders/table.tsx:31:24)' },
      { stream: 'err', text: `    at renderWithHooks (./node_modules/next/dist/compiled/react-dom/cjs/react-dom.development.js:15486:18)` },
    ];
  }
  if (r < 0.2) {
    return [
      { stream: 'out', text: ` ${c.cyan}○${c.reset} Compiling ${route} ...` },
      { stream: 'out', text: ` ${c.green}✓${c.reset} Compiled ${route} in ${randInt(180, 1400)}ms (${randInt(600, 1500)} modules)` },
    ];
  }
  return [{ stream: 'out', text: ` GET ${route.replace('[id]', String(randInt(1800, 1900)))} ${pick([200, 200, 200, 304])} in ${randInt(8, 240)}ms` }];
}

// ───────────── uvicorn ─────────────

function uvLevel(level: string): string {
  const col = level === 'INFO' ? c.green : level === 'WARNING' ? c.yellow : c.red;
  return `${col}${level}${c.reset}:${' '.repeat(Math.max(1, 9 - level.length))}`;
}

function uvicornStartup(ctx: SimCtx): Emit[] {
  const reload: Emit[] = ctx.reload
    ? [
        { stream: 'err', text: `${uvLevel('INFO')}Will watch for changes in these directories: ['${ctx.cwd}']` },
        { stream: 'err', text: `${uvLevel('INFO')}Uvicorn running on ${c.bold}http://${ctx.host}:${ctx.port}${c.reset} (Press CTRL+C to quit)` },
        { stream: 'err', text: `${uvLevel('INFO')}Started reloader process [${c.cyan}${c.bold}${ctx.pid}${c.reset}] using ${c.cyan}${c.bold}WatchFiles${c.reset}` },
      ]
    : [];
  return [
    ...reload,
    { stream: 'err', text: `${uvLevel('INFO')}Started server process [${c.cyan}${ctx.childPid}${c.reset}]` },
    { stream: 'err', text: `${uvLevel('INFO')}Waiting for application startup.` },
    { stream: 'out', text: 'Loading model weights from ./models/classifier-v3.onnx (412.7 MB)…' },
    { stream: 'err', text: `${uvLevel('INFO')}Application startup complete.` },
    ...(ctx.reload
      ? []
      : [{ stream: 'err' as const, text: `${uvLevel('INFO')}Uvicorn running on ${c.bold}http://${ctx.host}:${ctx.port}${c.reset} (Press CTRL+C to quit)` }]),
  ];
}

function uvicornTick(): Emit[] {
  const r = Math.random();
  if (r < 0.05) {
    return [
      { stream: 'err', text: `${uvLevel('ERROR')}Exception in ASGI application` },
      { stream: 'err', text: 'Traceback (most recent call last):' },
      { stream: 'err', text: '  File "/app/.venv/lib/python3.12/site-packages/uvicorn/protocols/http/httptools_impl.py", line 409, in run_asgi' },
      { stream: 'err', text: '    result = await app(  # type: ignore[func-returns-value]' },
      { stream: 'err', text: '  File "/app/app/main.py", line 58, in predict' },
      { stream: 'err', text: '    features = vectorize(payload.text)' },
      { stream: 'err', text: '  File "/app/app/features.py", line 21, in vectorize' },
      { stream: 'err', text: "    raise ValueError(f\"empty input: {text!r}\")" },
      { stream: 'err', text: "ValueError: empty input: ''" },
    ];
  }
  const route = pick(['POST /predict', 'POST /predict', 'GET /healthz', 'GET /docs', 'GET /openapi.json']);
  const status = route.startsWith('POST') ? pick(['200 OK', '200 OK', '422 Unprocessable Entity']) : '200 OK';
  const col = status.startsWith('2') ? c.green : c.yellow;
  return [{ stream: 'err', text: `${uvLevel('INFO')}127.0.0.1:${randInt(50000, 65000)} - "${route} HTTP/1.1" ${col}${status}${c.reset}` }];
}

function uvicornTerm(ctx: SimCtx): Emit[] {
  return [
    { stream: 'err', text: `${uvLevel('INFO')}Shutting down` },
    { stream: 'err', text: `${uvLevel('INFO')}Waiting for application shutdown.` },
    { stream: 'err', text: `${uvLevel('INFO')}Application shutdown complete.` },
    { stream: 'err', text: `${uvLevel('INFO')}Finished server process [${c.cyan}${ctx.childPid}${c.reset}]` },
    ...(ctx.reload ? [{ stream: 'err' as const, text: `${uvLevel('INFO')}Stopping reloader process [${c.cyan}${c.bold}${ctx.pid}${c.reset}]` }] : []),
  ];
}

// ───────────── docs (VitePress-ish) ─────────────

function docsStartup(ctx: SimCtx): Emit[] {
  return [
    { stream: 'out', text: `> docs-site@1.0.0 docs:preview ${ctx.cwd}` },
    { stream: 'out', text: '> vitepress build docs && vitepress preview docs' },
    { stream: 'out', text: '' },
    { stream: 'out', text: `  ${c.cyan}vitepress v1.5.0${c.fg}` },
    { stream: 'out', text: '' },
    { stream: 'out', text: `${c.green}✓${c.fg} building client + server bundles...` },
    { stream: 'out', text: `${c.green}✓${c.fg} rendering pages...` },
    { stream: 'out', text: `build complete in ${rand(2, 6).toFixed(2)}s.` },
  ];
}
function docsTick(_ctx: SimCtx, t: number): Emit[] {
  return [{ stream: 'out', text: `${c.dim}${clockTime(t)}${c.nobold} GET /guide/${pick(['getting-started', 'config', 'cli', 'faq'])}.html 200` }];
}

// ───────────── listening ports (v1.1-B) ─────────────

const SPRING_LIVERELOAD_PORT = 35729;

const DEFAULT_PORT: Record<ProfileKind, number> = { spring: 8080, uvicorn: 8000, docs: 4173, vite: 5173, next: 3000, generic: 0 };
/** Default bind address per stack (macOS): Tomcat/Next dual-stack "::", uvicorn 127.0.0.1, Vite "localhost" → ::1. */
const DEFAULT_HOST: Record<ProfileKind, string> = { spring: '::', uvicorn: '127.0.0.1', docs: '::1', vite: '::1', next: '::', generic: '127.0.0.1' };

/**
 * Port / host / profile the simulated program would end up with, read from the substituted
 * (secret-masked) argv and env — so a service started with ${apiPort}=8081 listens on 8081.
 */
export function deriveCtx(kind: ProfileKind, argv: string[], env: Record<string, string>): Pick<SimCtx, 'port' | 'host' | 'springProfile' | 'reload'> {
  const joined = ` ${argv.join(' ')} `;
  const m = (re: RegExp) => re.exec(joined)?.[1];
  const num = (v: string | undefined) => (v && /^\d{1,5}$/.test(v) && Number(v) > 0 && Number(v) < 65536 ? Number(v) : undefined);
  const port =
    num(m(/--server\.port=(\S+)/)) ??
    num(m(/\s--port[= ](\S+)/)) ??
    (kind === 'next' ? num(m(/\s-p[= ]?(\S+)/)) : undefined) ??
    num(env.SERVER_PORT) ??
    num(env.UVICORN_PORT) ??
    num(env.PORT) ??
    DEFAULT_PORT[kind];
  const hostOk = (v: string | undefined) => (v && /^[0-9a-fA-F:.]+$|^localhost$/.test(v) ? (v === 'localhost' ? '::1' : v) : undefined);
  const host =
    hostOk(m(/--server\.address=(\S+)/)) ??
    hostOk(m(/\s--host[= ](\S+)/)) ??
    (kind === 'next' ? hostOk(m(/\s-H[= ]?(\S+)/)) : undefined) ??
    hostOk(env.SERVER_ADDRESS) ??
    hostOk(env.UVICORN_HOST) ??
    DEFAULT_HOST[kind];
  const springProfile = m(/-Dspring-boot\.run\.profiles=(\S+)/) ?? m(/--spring\.profiles\.active=(\S+)/) ?? env.SPRING_PROFILES_ACTIVE ?? null;
  const reload = argv.includes('--reload') || env.UVICORN_RELOAD === 'true';
  return { port, host, springProfile, reload };
}

export function listeningPort(port: number, address: string, pid: number): ListeningPort {
  const family = address.includes(':') ? 'ipv6' : 'ipv4';
  const scope = address === '::1' || address.startsWith('127.') ? 'loopback' : address === '0.0.0.0' || address === '::' ? 'all' : 'other';
  return { port, address, family, scope, pid };
}

/** Sockets the simulated run will hold once started, and roughly when they appear (ms after spawn). */
export function listenPlan(p: SimProfile, ctx: SimCtx): { ports: ListeningPort[]; afterMs: number } {
  if (p.portConflict) return { ports: [], afterMs: 3000 };
  const pid = ctx.childPid;
  switch (p.kind) {
    case 'spring':
      // Tomcat on server.port/server.address, plus spring-boot-devtools LiveReload on all interfaces.
      return { ports: [listeningPort(ctx.port, ctx.host, pid), listeningPort(SPRING_LIVERELOAD_PORT, '0.0.0.0', pid)], afterMs: 5800 };
    case 'uvicorn':
      return { ports: [listeningPort(ctx.port, ctx.host, pid)], afterMs: 1600 };
    case 'next':
      return { ports: [listeningPort(ctx.port, ctx.host, pid)], afterMs: 2400 };
    case 'vite':
    case 'docs':
      return { ports: [listeningPort(ctx.port, ctx.host, pid)], afterMs: 900 };
    default:
      return { ports: [], afterMs: 500 };
  }
}

// ───────────── public API ─────────────

export function startupLines(p: SimProfile, ctx: SimCtx, t: number): Emit[] {
  switch (p.kind) {
    case 'spring':
      return springStartup(ctx, t);
    case 'vite':
      return viteStartup(ctx);
    case 'next':
      return nextStartup(ctx);
    case 'uvicorn':
      return uvicornStartup(ctx);
    case 'docs':
      return docsStartup(ctx);
    default:
      return [{ stream: 'out', text: 'started' }];
  }
}

export function tickLines(p: SimProfile, ctx: SimCtx, t: number): Emit[] {
  switch (p.kind) {
    case 'spring':
      return springTick(ctx, t);
    case 'vite':
      return viteTick(ctx, t);
    case 'next':
      return nextTick();
    case 'uvicorn':
      return uvicornTick();
    case 'docs':
      return docsTick(ctx, t);
    default:
      return [{ stream: 'out', text: `heartbeat ${clockTime(t)}` }];
  }
}

/** Mean delay between ticks in ms. */
export function tickInterval(p: SimProfile): number {
  switch (p.kind) {
    case 'spring':
      return 1600;
    case 'vite':
      return 7000;
    case 'next':
      return 4500;
    case 'uvicorn':
      return 2500;
    case 'docs':
      return 4000;
    default:
      return 5000;
  }
}

export function termLines(p: SimProfile, ctx: SimCtx, t: number): Emit[] {
  switch (p.kind) {
    case 'spring':
      return springTerm(ctx, t);
    case 'vite':
    case 'docs':
    case 'next':
      return viteTerm();
    case 'uvicorn':
      return uvicornTerm(ctx);
    default:
      return [];
  }
}

/** Lines for the bulk "flood" debug endpoint. */
export function floodLine(i: number, t: number): Emit {
  const r = i % 97;
  if (r === 13) return { stream: 'err', text: `${c.red}ERROR${c.reset} [worker-${i % 8}] request ${i} failed: java.util.concurrent.TimeoutException: deadline exceeded after 3000ms` };
  if (r === 42) return { stream: 'out', text: `${c.yellow}WARN${c.reset}  [worker-${i % 8}] slow query (${200 + (i % 800)}ms): SELECT * FROM orders WHERE customer_id = ${i % 5000} ORDER BY created_at DESC LIMIT 50` };
  return {
    stream: 'out',
    text: `${c.dim}${localIsoWithOffset(t)}${c.reset}  ${c.green}INFO${c.reset} [worker-${i % 8}] flood line #${i} OrderController handled GET /api/orders/${1000 + (i % 9000)} in ${i % 50}ms`,
  };
}
