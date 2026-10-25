/**
 * Seed data matching docs/ui-mockup.html. Roots live under the (virtual) user home;
 * nothing is created on disk and no real project is registered anywhere.
 */
import os from 'node:os';
import path from 'node:path';
import type { ParamConfig, ParamSetter, ProjectConfig } from '@devpanel/contract';
import { demoMavenModel } from './maven.ts';
import type { Engine } from './engine.ts';
import { iso } from './util.ts';
import { addVirtualDir, addVirtualFile } from './validate.ts';

const MIN = 60_000;
const HOUR = 60 * MIN;

/** A param as the daemon would store it: value set by `setBy` at `valueAt`, description written by the agent at `describedAt`. */
function param(p: ParamConfig, meta: { setBy: ParamSetter; valueAt: number; describedAt?: number; describedBy?: ParamSetter }): ParamConfig {
  return { ...p, setBy: meta.setBy, valueUpdatedAt: iso(meta.valueAt), describedBy: meta.describedBy ?? 'agent' };
}

export function seed(engine: Engine): void {
  const home = os.homedir();
  const proj = (...p: string[]) => path.join(home, 'Project', ...p);
  const now = Date.now();
  const registeredAt = now - 9 * 24 * HOUR;

  // ── order-service: Spring Boot + Next.js, both running ──
  // Params written by the agent at registration; the user later switched `host` to LAN while the
  // backend kept running with 127.0.0.1 → backend shows "选项已修改 · 下次启动生效", frontend does not.
  const orderRoot = proj('order-service');
  addVirtualDir(path.join(orderRoot, 'backend'));
  addVirtualDir(path.join(orderRoot, 'frontend'));
  addVirtualFile(path.join(orderRoot, 'backend', 'mvnw'));
  addVirtualFile(path.join(orderRoot, 'mvnw'));
  for (const module of demoMavenModel().modules) addVirtualFile(path.join(orderRoot, module.pomPath));
  const agentAt = registeredAt + 2 * MIN;
  const orderCfg: ProjectConfig = {
    schemaVersion: 1,
    name: 'order-service',
    root: orderRoot,
    params: [
      param(
        {
          key: 'profile',
          label: '后端配置',
          type: 'enum',
          value: 'dev',
          description:
            'Spring profile，决定后端读取 backend/src/main/resources 下的哪个 application-<profile>.yml。三份配置的主要差别是连接的数据库和日志级别；日常开发用 dev。',
          choices: [
            { value: 'dev', label: '本地开发', description: '连本机 Docker 里的 PostgreSQL（localhost:5432/order_dev），打印 SQL，启用 devtools 热重启。' },
            {
              value: 'test',
              label: '测试数据',
              description: '连 order_test 库，启动时 Flyway 执行 db/migration 全部脚本并导入 data-test.sql 里的 200 条样例订单。会清空该库。',
            },
            {
              value: 'prod',
              label: '类生产',
              description: '关闭 SQL 日志和 devtools，连接池加大到 20，数据库地址取 DB_URL 环境变量。本机通常没有该库，只用于排查生产配置问题。',
            },
          ],
        },
        { setBy: 'agent', valueAt: agentAt },
      ),
      param(
        {
          key: 'apiPort',
          label: '后端端口',
          type: 'number',
          value: 8081,
          min: 1024,
          max: 65535,
          description:
            '后端 HTTP 端口（server.port）。README 提到 8080 常与本机的 Jenkins 冲突，所以默认用 8081。前端的 NEXT_PUBLIC_API_BASE 也引用这个值，改了前后端会一起变（两边都要重启）。',
        },
        { setBy: 'agent', valueAt: agentAt },
      ),
      param(
        {
          key: 'host',
          label: '监听地址',
          type: 'enum',
          value: '0.0.0.0',
          description: '后端绑定的网卡（server.address）。用手机真机调试前端页面时需要局域网可访问。',
          choices: [
            { value: '127.0.0.1', label: '仅本机', description: '只有这台电脑能访问后端。' },
            {
              value: '0.0.0.0',
              label: '局域网可访问',
              description: '同一网络的手机和其他电脑也能访问。注意 dev 配置下 /actuator 没有鉴权。',
            },
          ],
        },
        { setBy: 'user', valueAt: now - 20 * MIN },
      ),
    ],
    actions: [
      { id: 'build', name: '构建 · 当前环境', description: '引用当前 Profile 构建后端', cwd: 'backend', command: ['./mvnw', 'package', '-P${profile}'], timeoutSec: 300 },
      { id: 'clean', name: 'clean install', description: '清理 target 后重新构建，运行中的服务可能受影响。', cwd: 'backend', command: ['./mvnw', 'clean', 'install'], confirmWhenServicesRunning: true },
      { id: 'fail-demo', name: '测试失败示例', description: '模拟失败输出与退出码 1', cwd: 'backend', command: ['./mvnw', 'test'] },
    ],
    services: [
      {
        id: 'backend',
        name: '后端',
        cwd: 'backend',
        command: [
          './mvnw',
          'spring-boot:run',
          '-Dspring-boot.run.profiles=${profile}',
          '-Dspring-boot.run.arguments=--server.port=${apiPort} --server.address=${host}',
        ],
        env: {
          JAVA_HOME: '/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home',
          DB_PASSWORD: { secret: true, value: 'mock-db-password' },
        },
        stopTimeoutSec: 10,
      },
      {
        id: 'frontend',
        name: '前端',
        cwd: 'frontend',
        command: ['pnpm', 'exec', 'next', 'dev', '-p', '3000'],
        env: { NEXT_PUBLIC_API_BASE: 'http://localhost:${apiPort}' },
      },
    ],
  };
  /** Values the currently running backend was started with (before the user switched host). */
  const orderStartValues = { host: '127.0.0.1' };
  const order = engine.seedProject(orderCfg, { revision: 3, createdAt: registeredAt, id: 'p_ordersvc2a' });
  engine.seedMaven(order.project.id, demoMavenModel());
  engine.seedGit(order.project.id);
  const curStart = now - (HOUR + 12 * MIN);
  // backend: yesterday failed (port in use, truncated), earlier today stopped, current running with older config
  engine.seedHistoricRun(order, 'backend', {
    startedAt: now - 17 * HOUR,
    endedAt: now - 17 * HOUR + 88 * MIN,
    reason: 'self-exit',
    code: 1,
    signal: null,
    configRevision: 1,
    ticks: 2600,
    portConflict: false,
    dropFirst: 600,
    paramValues: orderStartValues,
  });
  engine.seedHistoricRun(order, 'backend', {
    startedAt: curStart - 88 * MIN,
    endedAt: curStart - 60_000,
    reason: 'user-stop',
    code: null,
    signal: 'SIGTERM',
    configRevision: 2,
    ticks: 900,
    paramValues: { ...orderStartValues, profile: 'test' },
  });
  engine.seedLiveRun(order, 'backend', {
    startedAt: curStart,
    configRevision: 2,
    paramValues: orderStartValues, // host changed since: "选项已修改 · 下次启动生效"
  });
  engine.seedHistoricRun(order, 'frontend', {
    startedAt: now - 17 * HOUR,
    endedAt: now - 17 * HOUR + 88 * MIN,
    reason: 'user-stop',
    code: null,
    signal: 'SIGTERM',
    configRevision: 1,
    ticks: 120,
  });
  engine.seedHistoricRun(order, 'frontend', {
    startedAt: curStart - 88 * MIN,
    endedAt: curStart - 60_000,
    reason: 'user-stop',
    code: null,
    signal: 'SIGTERM',
    configRevision: 2,
    ticks: 80,
  });
  engine.seedLiveRun(order, 'frontend', { startedAt: curStart + 4000, configRevision: 2 });

  // ── web-admin: single service, running; ignores SIGTERM → needs force-stop ──
  const webRoot = proj('web-admin');
  addVirtualDir(webRoot);
  const web = engine.seedProject(
    {
      schemaVersion: 1,
      name: 'web-admin',
      root: webRoot,
      services: [{ id: 'web', name: 'web-admin', cwd: '.', command: ['pnpm', 'dev'], stopTimeoutSec: 10 }],
    },
    { revision: 1, createdAt: registeredAt + HOUR, id: 'p_webadmin22' },
  );
  engine.setProfile(web, 'web', { kind: 'vite', hangOnStop: true, cpu: 0.3, rssMiB: 214 });
  engine.seedHistoricRun(web, 'web', { startedAt: now - 30 * HOUR, endedAt: now - 28 * HOUR, reason: 'force-stop', code: null, signal: 'SIGKILL', ticks: 60 });
  engine.seedHistoricRun(web, 'web', { startedAt: now - 5 * HOUR, endedAt: now - 3 * HOUR, reason: 'force-stop', code: null, signal: 'SIGKILL', ticks: 60 });
  engine.seedLiveRun(web, 'web', { startedAt: now - 26 * MIN });

  // ── ml-api: Python (uvicorn), never started; port / reload / secret token params ──
  const mlRoot = proj('ml-api');
  addVirtualDir(mlRoot);
  const mlAgentAt = registeredAt + 2 * HOUR + MIN;
  engine.seedProject(
    {
      schemaVersion: 1,
      name: 'ml-api',
      root: mlRoot,
      env: { PYTHONUNBUFFERED: '1' },
      params: [
        param(
          {
            key: 'port',
            label: '接口端口',
            type: 'number',
            value: 8000,
            min: 1024,
            max: 65535,
            description: 'uvicorn 监听端口。app/config.py 的 CORS 白名单写死了 localhost:8000，改端口后浏览器里的调试页会跨域失败，需要同步改那里。',
          },
          { setBy: 'agent', valueAt: mlAgentAt },
        ),
        param(
          {
            key: 'reload',
            label: '自动重载',
            type: 'boolean',
            value: true,
            description:
              '开启后 uvicorn 监视 app/ 下的 .py 文件，保存即重启 worker。每次重启要重新加载 412 MB 的模型（约 6 秒），频繁保存时可以关掉。通过 UVICORN_RELOAD 环境变量传给 uvicorn。',
          },
          { setBy: 'agent', valueAt: mlAgentAt },
        ),
        param(
          {
            key: 'hfToken',
            label: 'Hugging Face 令牌',
            type: 'string',
            secret: true,
            value: 'mock-hf-token',
            description: 'app/model.py 首次启动时用它从 Hugging Face Hub 下载 tokenizer。下载后缓存在 ~/.cache/huggingface，之后留空也能启动。',
          },
          { setBy: 'user', valueAt: mlAgentAt + 40 * MIN },
        ),
      ],
      services: [
        {
          id: 'api',
          name: 'ml-api',
          cwd: '.',
          command: ['uv', 'run', 'uvicorn', 'app.main:app', '--port', '${port}'],
          env: { UVICORN_RELOAD: '${reload}', HF_TOKEN: '${hfToken}' },
        },
      ],
    },
    { revision: 1, createdAt: registeredAt + 2 * HOUR, id: 'p_mlapi22222' },
  );

  // ── order-service (archive/): same name, different root; last run failed with exit 1 ──
  const archRoot = proj('archive', 'order-service');
  addVirtualDir(path.join(archRoot, 'backend'));
  addVirtualFile(path.join(archRoot, 'backend', 'mvnw'));
  const arch = engine.seedProject(
    {
      schemaVersion: 1,
      name: 'order-service',
      root: archRoot,
      services: [
        { id: 'backend', name: 'order-service', cwd: 'backend', command: ['./mvnw', 'spring-boot:run'] },
      ],
    },
    { revision: 2, createdAt: registeredAt + 3 * HOUR, id: 'p_archorder2' },
  );
  engine.setProfile(arch, 'backend', { kind: 'spring', portConflict: true });
  engine.seedHistoricRun(arch, 'backend', { startedAt: now - 50 * HOUR, endedAt: now - 47 * HOUR, reason: 'user-stop', code: null, signal: 'SIGTERM', ticks: 300, configRevision: 1 });
  engine.seedHistoricRun(arch, 'backend', { startedAt: now - 26 * HOUR, endedAt: now - 25 * HOUR, reason: 'user-stop', code: null, signal: 'SIGTERM', ticks: 200, configRevision: 2 });
  engine.seedHistoricRun(arch, 'backend', {
    startedAt: now - 2 * HOUR,
    endedAt: now - 2 * HOUR + 6000,
    reason: 'self-exit',
    code: 1,
    signal: null,
    configRevision: 2,
    portConflict: true,
  });

  // ── docs-site: exited on its own with code 0 ──
  const docsRoot = proj('docs-site');
  addVirtualDir(docsRoot);
  const docs = engine.seedProject(
    {
      schemaVersion: 1,
      name: 'docs-site',
      root: docsRoot,
      services: [{ id: 'docs', name: 'docs-site', cwd: '.', command: ['pnpm', 'docs:preview'] }],
    },
    { revision: 1, createdAt: registeredAt + 4 * HOUR, id: 'p_docssite22' },
  );
  engine.setProfile(docs, 'docs', { kind: 'docs', exitAfterMs: 25_000, exitCode: 0 });
  engine.seedHistoricRun(docs, 'docs', { startedAt: now - 72 * HOUR, endedAt: now - 70 * HOUR, reason: 'user-stop', code: null, signal: 'SIGTERM', ticks: 40 });
  engine.seedHistoricRun(docs, 'docs', { startedAt: now - 30 * HOUR, endedAt: now - 29 * HOUR, reason: 'self-exit', code: 0, signal: null, ticks: 30 });
  engine.seedHistoricRun(docs, 'docs', { startedAt: now - 3 * HOUR, endedAt: now - 3 * HOUR + 40 * MIN, reason: 'self-exit', code: 0, signal: null, ticks: 30 });

  // ── shop-portal: two services; "web" has a PATH without pnpm → start ends `partial` ──
  const shopRoot = proj('shop-portal');
  addVirtualDir(path.join(shopRoot, 'api'));
  addVirtualDir(path.join(shopRoot, 'web'));
  engine.seedProject(
    {
      schemaVersion: 1,
      name: 'shop-portal',
      root: shopRoot,
      services: [
        { id: 'api', name: '接口', cwd: 'api', command: ['uv', 'run', 'uvicorn', 'shop.main:app', '--reload'] },
        {
          id: 'web',
          name: '前端',
          cwd: 'web',
          command: ['pnpm', 'dev'],
          // Registered when pnpm was still on this PATH; it has since been removed (nvm/corepack change).
          env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin' },
        },
      ],
    },
    { revision: 1, createdAt: registeredAt + 5 * HOUR, id: 'p_shopportal' },
  );
  const project = engine.projects[0]!;
  const actors = [{ client: 'cli' as const, agent: 'claude-code' }, { client: 'cli' as const, agent: 'codex' }, { client: 'cli' as const, agent: null }, { client: 'ui' as const, agent: null }, { client: 'daemon' as const, agent: null }];
  for (const [index, actor] of actors.entries()) {
    engine.activity.config(project.project.id, actor, 'update', index + 1, index + 2,
      { env: { API_TOKEN: { secret: true, value: 'old-private' } }, name: '演示' + index },
      { env: { API_TOKEN: { secret: true, value: 'new-private' } }, name: '演示' + (index + 1) });
  }
  for (const [index, svc] of [...project.services.values()].entries()) {
    for (const run of svc.runs) {
      run.summary.startedBy = actors[index % actors.length]!;
      if (run.summary.exit) run.summary.exit.requestedBy = ['user-stop', 'force-stop', 'start-cancelled'].includes(run.summary.exit.reason) ? actors[3]! : null;
    }
  }
  // Isolated virtual readiness examples (no filesystem writes or command execution).
  const readyRoot = proj('readiness-demo'); addVirtualDir(readyRoot);
  const readyDemo = engine.seedProject({schemaVersion:1,name:'就绪演示',root:readyRoot,params:[param({key:'port',label:'监听端口',type:'number',value:8080},{setBy:'agent',valueAt:now})],services:[
    {id:'log',name:'日志就绪',cwd:'.',command:['node','server.js'],ready:{check:{kind:'log',contains:['ready in']}}},
    {id:'port',name:'端口就绪',cwd:'.',command:['node','server.js','--port=${port}'],ready:{check:{kind:'port',port:'${port}'}}},
    {id:'timeout',name:'等待超时',cwd:'.',command:['node','server.js'],ready:{check:{kind:'log',contains:['NEVER MATCH']},timeoutSec:1}},
    {id:'plain',name:'未配置',cwd:'.',command:['node','server.js']}
  ]},{revision:1,createdAt:now,id:'p_readinessdemo'});
  for (const sid of ['log','port','timeout','plain']) engine.seedLiveRun(readyDemo,sid,{startedAt:now-5000});
  const logRun=engine.runsOf('p_readinessdemo','log')[0];
  if(logRun) engine.appendLog(engine.findLogRun(logRun.id),'out','ready in 320 ms',now);

  const pausedProject = engine.projects.find(p => [...p.services.values()].some(s => s.state === 'stopped')) ?? engine.projects[1]!;
  const paused = [...pausedProject.services.values()].find(s => s.state === 'stopped') ?? [...pausedProject.services.values()][0]!;
  engine.policies.holds[pausedProject.project.id] = { [paused.id]: { since: iso(now - 3 * MIN), operationId: 'op_seed_hold' } };
  const locked = project.project.config.services[0]!;
  engine.setPolicy(project.project.id, { holdAfterUserStop: true, agentForceStop: 'deny', lockedServices: [locked.id] }, { client: 'ui', agent: null });

}
