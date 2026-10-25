#!/usr/bin/env node
// 本地发布包：不推送、不创建标签，不写入任何用户安装目录。
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync, chmodSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const version = process.env.VERSION ?? '0.4.1';
if (!/^[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.-]+)?$/.test(version)) throw Error('VERSION 格式无效');
if (process.platform !== 'darwin' || !['arm64', 'x64'].includes(process.arch)) throw Error('仅在 macOS arm64/x64 本机打包');
const output = resolve(process.argv[2] ?? join(root, '.devpanel-dev/codex/v04/release'));
// 防止清理产物时误指向手工稳定版或已安装 App。
if (!output.startsWith(root + '/') || !output.includes('/.devpanel-dev/')) throw Error('输出必须位于本仓库 .devpanel-dev/ 下');
const run = (program, args, extra = {}) => execFileSync(program, args, { cwd: root, stdio: 'inherit', ...extra });
const nodeVersion = '24.21.0';
const archive = `node-v${nodeVersion}-darwin-${process.arch}.tar.gz`;
const cache = join(root, '.devpanel-dev/codex/v04/node');
mkdirSync(cache, { recursive: true });
for (const file of ['SHASUMS256.txt', archive]) {
  if (!existsSync(join(cache, file))) run('/usr/bin/curl', ['--fail', '--location', `https://nodejs.org/dist/v${nodeVersion}/${file}`, '-o', join(cache, file)]);
}
const expected = readFileSync(join(cache, 'SHASUMS256.txt'), 'utf8').split('\n').find(line => line.endsWith(`  ${archive}`))?.split(' ')[0];
const actual = createHash('sha256').update(readFileSync(join(cache, archive))).digest('hex');
if (!expected || actual !== expected) throw Error('Node 官方发行包 SHA-256 不匹配');
const nodeDistribution = join(cache, `node-v${nodeVersion}-darwin-${process.arch}`);
if (!existsSync(join(nodeDistribution, 'bin/node'))) run('/usr/bin/tar', ['-xzf', join(cache, archive), '-C', cache]);
const linkage = execFileSync('/usr/bin/otool', ['-L', join(nodeDistribution, 'bin/node')], { encoding: 'utf8' });
if (linkage.includes('/opt/') || linkage.includes('/usr/local/')) throw Error('Node 依赖包外动态库，拒绝发布');

run(process.execPath, ['packages/daemon/src/native-build.ts']);
run('/bin/sh', ['apps/mac/scripts/bundle.sh', output], { env: { ...process.env, VERSION: version } });
const app = join(output, 'DevPanel.app');
// 随 App 一并分发项目许可与第三方声明；依赖各自的许可证仍保留在 runtime 中。
for (const name of ['LICENSE', 'THIRD_PARTY_NOTICES.md']) {
  cpSync(join(root, name), join(app, 'Contents/Resources', name));
}
const runtime = join(app, 'Contents/Resources/runtime');
mkdirSync(join(runtime, 'node/bin'), { recursive: true });
cpSync(join(nodeDistribution, 'bin/node'), join(runtime, 'node/bin/node'));
cpSync(join(nodeDistribution, 'LICENSE'), join(runtime, 'node/LICENSE'));
writeFileSync(join(runtime, 'package.json'), JSON.stringify({ private: true, type: 'module' }));

// 生产依赖按实际安装路径递归复制；保留包内许可证，不携带 pnpm、npm 或开发依赖。
const copied = new Map();
function copyDependency(name, from) {
  const require = createRequire(join(from, 'package.json'));
  const modules = require.resolve.paths(name)?.find(path => existsSync(join(path, name, 'package.json')));
  if (!modules) throw Error(`找不到生产依赖：${name}`);
  const source = realpathSync(join(modules, name));
  if (copied.has(name)) {
    if (copied.get(name) !== source) throw Error(`生产依赖存在多个版本：${name}`);
    return;
  }
  copied.set(name, source);
  const target = join(runtime, 'node_modules', name);
  mkdirSync(dirname(target), { recursive: true });
  cpSync(source, target, { recursive: true, filter: path => !path.slice(source.length).split('/').includes('node_modules') });
  const manifest = JSON.parse(readFileSync(join(source, 'package.json'), 'utf8'));
  for (const child of Object.keys(manifest.dependencies ?? {})) copyDependency(child, source);
}
for (const name of ['contract', 'daemon', 'cli']) {
  const source = join(root, 'packages', name), target = join(runtime, 'packages', name);
  mkdirSync(target, { recursive: true });
  cpSync(join(source, 'src'), join(target, 'src'), { recursive: true });
  const manifest = JSON.parse(readFileSync(join(source, 'package.json'), 'utf8'));
  manifest.version = version;
  writeFileSync(join(target, 'package.json'), JSON.stringify(manifest, null, 2) + '\n');
  for (const dep of Object.keys(manifest.dependencies ?? {})) if (!dep.startsWith('@devpanel/')) copyDependency(dep, source);
  mkdirSync(join(runtime, 'node_modules/@devpanel'), { recursive: true });
  symlinkSync(`../../packages/${name}`, join(runtime, 'node_modules/@devpanel', name));
}
mkdirSync(join(runtime, 'packages/daemon/native/build'), { recursive: true });
cpSync(join(root, 'packages/daemon/native/process-sampler.c'), join(runtime, 'packages/daemon/native/process-sampler.c'));
cpSync(join(root, 'packages/daemon/native/build/process-sampler'), join(runtime, 'packages/daemon/native/build/process-sampler'));
mkdirSync(join(runtime, 'bin'), { recursive: true });
for (const [name, pkg] of [['devpanel', 'cli'], ['devpaneld', 'daemon']]) {
  const path = join(runtime, 'bin', name);
  writeFileSync(path, `#!/bin/sh
# DevPanel 内置命令入口；安装软链接后仍按真实入口位置寻找运行时。
ENTRY="$0"
while [ -L "$ENTRY" ]; do
  BASE=$(CDPATH= cd -- "$(dirname -- "$ENTRY")" && pwd)
  LINK=$(/usr/bin/readlink "$ENTRY")
  case "$LINK" in /*) ENTRY="$LINK" ;; *) ENTRY="$BASE/$LINK" ;; esac
done
BASE=$(CDPATH= cd -- "$(dirname -- "$ENTRY")/.." && pwd)
exec "$BASE/node/bin/node" "$BASE/packages/${pkg}/src/main.ts" "$@"
`);
  chmodSync(path, 0o755);
}
writeFileSync(join(runtime, 'runtime.json'), JSON.stringify({ version, nodeVersion, arch: process.arch, nodeArchiveSHA256: actual }, null, 2) + '\n');
// 对嵌入的 Mach-O 先签名，再签外层；不使用 --deep 掩盖未签的内容。
for (const path of ['node/bin/node', 'packages/daemon/native/build/process-sampler']) run('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', join(runtime, path)]);
run('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', app]);
run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
const zipName = `DevPanel-${version}-macos-${process.arch}.zip`;
const zip = join(output, zipName);
if (existsSync(zip)) rmSync(zip);
run('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, zip]);
const sha = createHash('sha256').update(readFileSync(zip)).digest('hex');
writeFileSync(zip + '.sha256', `${sha}  ${zipName}\n`);
console.log(`本地发布包：${zip}\nSHA-256：${sha}`);
