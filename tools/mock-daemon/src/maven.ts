/** Static mock Maven data and structured command construction. No Maven process or XML is executed. */
import type { MavenModel, MavenModule, MavenRunRequest } from '@devpanel/contract';
import { HttpError } from './errors.ts';
import { iso } from './util.ts';

export function demoMavenModel(): MavenModel {
  const module = (id: string, fields: Partial<MavenModule> = {}): MavenModule => ({
    id, pomPath: id === '.' ? 'pom.xml' : `${id}/pom.xml`, parentId: id === '.' ? null : '.',
    groupId: 'com.example.orders', artifactId: id === '.' ? 'order-service' : id,
    name: null, packaging: 'jar', profiles: [], parentOutside: false, error: null, ...fields,
  });
  const modules = [
    module('.', { name: 'Order Service', packaging: 'pom', profiles: ['dev', 'local-db'] }),
    module('backend', { name: 'Order Backend', profiles: ['integration'] }),
    module('contracts', { name: 'Public Contracts' }),
    module('external-parent', { groupId: 'com.example.platform', name: 'External Parent Example', parentOutside: true }),
    module('broken', { error: 'pom.xml 第 8 行：缺少 </artifactId> 结束标签' }),
  ];
  return { executable: 'wrapper', modules, profiles: [...new Set(modules.flatMap(m => m.profiles))], scannedAt: iso() };
}

export function validateMavenRun(input: unknown, model: MavenModel): MavenRunRequest {
  const invalid = (field: string): never => { throw new HttpError(422, 'MAVEN_INVALID', `Maven 参数无效：${field}`, { field }); };
  if (!input || typeof input !== 'object' || Array.isArray(input)) return invalid('request');
  const body = input as Record<string, unknown>;
  const fields = new Set(['moduleId', 'goals', 'profiles', 'skipTests', 'offline', 'alsoMake', 'mavenProjectId']);
  for (const key of Object.keys(body)) if (!fields.has(key)) invalid(key);
  if (body.mavenProjectId !== undefined && typeof body.mavenProjectId !== 'string') invalid('mavenProjectId');
  if (typeof body.moduleId !== 'string' || !model.modules.some(m => m.id === body.moduleId)) invalid('moduleId');
  if (!Array.isArray(body.goals) || !body.goals.length || !body.goals.every(g => typeof g === 'string' && !g.startsWith('-') && /^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+){0,3}(@[A-Za-z0-9_.-]+)?$/.test(g))) invalid('goals');
  if (body.profiles !== undefined && (!Array.isArray(body.profiles) || !body.profiles.every(p => typeof p === 'string' && /^!?[A-Za-z0-9_.-]+$/.test(p)))) invalid('profiles');
  for (const key of ['skipTests', 'offline', 'alsoMake']) if (body[key] !== undefined && typeof body[key] !== 'boolean') invalid(key);
  return structuredClone(body) as unknown as MavenRunRequest;
}

export function mavenCommand(model: MavenModel, request: MavenRunRequest): string[] {
  return [model.executable === 'wrapper' ? './mvnw' : 'mvn',
    ...(request.moduleId === '.' ? [] : ['-pl', request.moduleId, ...(request.alsoMake ? ['-am'] : [])]),
    ...(request.skipTests ? ['-DskipTests'] : []), ...(request.offline ? ['-o'] : []),
    ...(request.profiles?.length ? [`-P${request.profiles.join(',')}`] : []), ...request.goals];
}

export function mavenOutput(model: MavenModel, request: MavenRunRequest): { lines: string[]; failed: boolean } {
  const selected = request.moduleId === '.' ? model.modules : model.modules.filter(m => m.id === request.moduleId || (request.alsoMake && m.id === 'contracts'));
  const failed = selected.some(m => m.error !== null) || request.profiles?.includes('mock-failure') === true;
  const lines = ['[INFO] Scanning for projects...', '[INFO] Reactor Build Order:', ...selected.map(m => `[INFO] ${m.artifactId.padEnd(36)} [${m.packaging}]`)];
  for (const m of selected) {
    lines.push(`[INFO] ----------------< ${m.groupId}:${m.artifactId} >----------------`, `[INFO] Building ${m.name ?? m.artifactId} 1.0-SNAPSHOT`);
    if (m.error) { lines.push(`[ERROR] Non-parseable POM ${m.pomPath}: ${m.error}`); continue; }
    for (const goal of request.goals) lines.push(`[INFO] --- ${goal.includes(':') ? goal : `maven-${goal}-plugin:3.4.1:${goal}`} (default-cli) @ ${m.artifactId} ---`);
    lines.push(request.skipTests ? '[INFO] Tests are skipped.' : '[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0');
  }
  lines.push('[WARNING] Mock Maven output: no dependency downloads or project commands are executed.', '[INFO] Reactor Summary:', ...selected.map(m => `[INFO] ${m.artifactId} ........ ${m.error ? 'FAILURE' : 'SUCCESS'}`));
  if (failed) lines.push('[ERROR] Failed to execute goal: simulated build failure.');
  lines.push(failed ? '[INFO] BUILD FAILURE' : '[INFO] BUILD SUCCESS');
  return { lines, failed };
}
