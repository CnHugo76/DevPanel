# 独立演示

这个小型 HTTP 服务只依赖 Node，监听 `127.0.0.1`，不需要现有项目或真实配置。先在仓库根目录完成 `pnpm install --frozen-lockfile`，然后在同一个终端执行：

```sh
export DEVPANEL_HOME="$(mktemp -d /tmp/dp-demo.XXXXXX)"
export DEVPANEL_PORT=0

# 生成隔离配置，使用当前 Node 的绝对路径；此步骤不执行服务。
node --input-type=module <<'JS'
import { writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
writeFileSync(join(process.env.DEVPANEL_HOME, 'demo.json'), JSON.stringify({
  schemaVersion: 1,
  name: 'DevPanel demo',
  root: resolve('examples/demo'),
  repositories: [],
  mavenProjects: [],
  params: [{
    key: 'port', label: 'HTTP port', type: 'number',
    value: 43123, min: 1024, max: 65535,
  }],
  services: [{
    id: 'web', name: 'Demo HTTP', cwd: '.',
    command: [process.execPath, 'server.mjs', '${port}'],
    ready: { check: { kind: 'log', contains: ['Demo ready at'] }, timeoutSec: 15 },
  }],
}, null, 2) + '\n');
JS

node packages/cli/src/main.ts daemon start --json
node packages/cli/src/main.ts project validate --config "$DEVPANEL_HOME/demo.json" --json
node packages/cli/src/main.ts project register --config "$DEVPANEL_HOME/demo.json" --json
```

记下注册响应中的 `project.id`，替换下文的 `PROJECT_ID`。端口占用时，可先用源码 CLI 的 `param set PROJECT_ID port 43124 --json` 修改示例端口，并同步调整下面的 curl URL。

```sh
node packages/cli/src/main.ts start PROJECT_ID --wait-ready --json
curl http://127.0.0.1:43123/
node packages/cli/src/main.ts logs PROJECT_ID --service web --digest
node packages/cli/src/main.ts activity PROJECT_ID --json
```

也可在同一终端运行开发 App 的可执行文件，查看相同项目。打包说明见 [apps/mac/README.md](../../apps/mac/README.md)。

体验后，在保留上述环境变量的同一终端执行：

```sh
node packages/cli/src/main.ts stop PROJECT_ID --json
node packages/cli/src/main.ts project remove PROJECT_ID --json
node packages/cli/src/main.ts daemon stop --json
```

确认 daemon 已停止后，临时目录可自行删除。这个示例的项目登记和运行都只存在于临时数据目录。
