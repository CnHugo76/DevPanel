// Generates an isolated demo directory. Registration and execution stay explicit.
import { copyFileSync, constants, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createDemo } from '../demo/create-config.mjs';

const file = createDemo(process.argv[2]);
const config = JSON.parse(readFileSync(file, 'utf8'));
config.name = 'Action parameter demo';
config.actions = [{
  id: 'deploy-demo', name: '示例打包部署', description: '演示参数传递；不会部署服务或访问数据库。', cwd: '.',
  command: [process.execPath, 'deploy-demo.mjs', '${action.services}'],
  env: { BACKUP_DATABASE: '${action.backup}' }, runLabel: '开始部署',
  params: [
    { key: 'services', label: '部署服务', type: 'multiselect', required: true, default: ['frontend', 'backend'], choices: [{ value: 'frontend', label: '前端' }, { value: 'backend', label: '后端' }, { value: 'runtime', label: 'Runtime' }] },
    { key: 'backup', label: '备份数据库', type: 'boolean', default: true },
  ],
}];
copyFileSync(fileURLToPath(new URL('deploy-demo.mjs', import.meta.url)), join(config.root, 'deploy-demo.mjs'), constants.COPYFILE_EXCL);
writeFileSync(file, JSON.stringify(config, null, 2) + '\n', { mode: 0o600 });
console.log(file);
