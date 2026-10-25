import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { basename, isAbsolute, join, relative, resolve } from "node:path";
import { createRequire } from "node:module";
import type { MavenModel, MavenModule, MavenRunRequest, ProjectConfig } from "@devpanel/contract";
import { effectiveEnv, findProgram, type BaseEnv } from "./config.ts";
import { expandService } from "./params.ts";
import { Fault, now } from "./storage.ts";
const inside = (root: string, path: string) => { const rel = relative(root, path); return !isAbsolute(rel) && rel !== ".." && !rel.startsWith("../"); };
const list = (value: unknown): any[] => value === undefined ? [] : Array.isArray(value) ? value : [value];
const text = (value: unknown): string | null => typeof value === "string" && value.trim() ? value.trim() : null;
const stamp = (path: string) => { try { const s = statSync(path); return `${realpathSync(path)}:${s.mtimeMs}:${s.ctimeMs}:${s.size}`; } catch { return "missing"; } };
const require = createRequire(import.meta.url);
export function mavenExecutable(config: ProjectConfig, base: BaseEnv) {
  const env = effectiveEnv(base, expandService(config, { id: "maven", name: "Maven", cwd: ".", command: ["mvn"] }).env);
  const wrapper = findProgram("./mvnw", config.root, env.PATH || "");
  const mode = config.maven?.executable ?? "auto";
  const executable = mode === "wrapper" || (mode === "auto" && wrapper) ? "wrapper" : "mvn";
  const program = executable === "wrapper" ? wrapper : findProgram("mvn", config.root, env.PATH || "");
  if (!program) throw new Fault("COMMAND_NOT_FOUND", executable === "wrapper" ? "找不到可执行的 mvnw" : "有效 PATH 中找不到 mvn", 422);
  return { executable: executable as MavenModel["executable"], program };
}
export class MavenModels {
  private cache = new Map<string, { files: Map<string, string>; model: Omit<MavenModel, "executable"> }>();
  has(root: string) { return existsSync(join(root, "pom.xml")); }
  read(config: ProjectConfig, base: BaseEnv, reload = false): MavenModel {
    if (!this.has(config.root)) throw new Fault("MAVEN_UNAVAILABLE", "项目根没有 pom.xml", 404);
    const executable = mavenExecutable(config, base).executable;
    const root = realpathSync(config.root);
    let cached = this.cache.get(root);
    if (!cached || reload || [...cached.files].some(([path, value]) => stamp(path) !== value)) {
      // Keep XML parser code and its working heap out of the daemon's idle path.
      const { XMLParser, XMLValidator } = require("fast-xml-parser") as typeof import("fast-xml-parser");
      const parser = new XMLParser({ ignoreAttributes: true, removeNSPrefix: true, parseTagValue: false, processEntities: true });
      const files = new Map<string, string>();
      const modules: MavenModule[] = [];
      const seen = new Set<string>();
      const realSeen = new Set<string>();
      const visit = (dir: string, parentId: string | null) => {
        const id = relative(root, dir) || ".";
        if (seen.has(id)) return;
        seen.add(id);
        const pom = join(dir, "pom.xml");
        const module: MavenModule = { id, pomPath: relative(root, pom), parentId, groupId: null, artifactId: basename(dir), name: null, packaging: "jar", profiles: [], parentOutside: false, error: null };
        modules.push(module);
        try {
          if (!inside(root, dir) || (existsSync(pom) && !inside(root, realpathSync(pom)))) throw new Error("模块 POM 不在项目内");
          files.set(pom, stamp(pom));
          const actual = realpathSync(dir);
          if (realSeen.has(actual)) throw new Error("模块重复引用或循环");
          realSeen.add(actual);
          if (modules.length > 1000) throw new Error("模块数量超过 1000");
          if (statSync(pom).size > 2 * 1024 * 1024) throw new Error("POM 超过 2 MiB");
          const xml = readFileSync(pom, "utf8");
          if (/<!DOCTYPE|<!ENTITY/i.test(xml)) throw new Error("不支持 DTD 或外部实体");
          const valid = XMLValidator.validate(xml);
          if (valid !== true) throw new Error(`XML: ${valid.err.msg}`);
          const p = parser.parse(xml).project;
          if (!p || typeof p !== "object" || !text(p.artifactId)) throw new Error("POM 缺少 project/artifactId");
          module.groupId = text(p.groupId) ?? text(p.parent?.groupId);
          module.artifactId = text(p.artifactId)!;
          module.name = text(p.name); module.packaging = text(p.packaging) ?? "jar";
          module.profiles = list(p.profiles?.profile).map(v => text(v.id)).filter((v): v is string => !!v);
          if (p.parent) {
            const parent = resolve(dir, text(p.parent.relativePath) ?? "../pom.xml");
            module.parentOutside = p.parent.relativePath === "" || !inside(root, parent) || !existsSync(parent) || !inside(root, realpathSync(parent));
            if (inside(root, parent)) files.set(parent, stamp(parent));
          }
          for (const child of list(p.modules?.module)) {
            const childPath = text(child);
            if (childPath) visit(resolve(dir, childPath), id);
          }
        } catch (e) { module.error = e instanceof Error ? e.message : "无法读取 POM"; }
      };
      visit(root, null);
      cached = { files, model: { modules, profiles: [...new Set(modules.flatMap(m => m.profiles))], scannedAt: now() } };
      this.cache.set(root, cached);
    }
    return { ...structuredClone(cached.model), executable };
  }
}
export function mavenCommand(input: unknown, model: MavenModel): { request: MavenRunRequest; command: string[] } {
  const invalid = (field: string): never => { throw new Fault("MAVEN_INVALID", `Maven 参数无效：${field}`, 422, { field }); };
  if (!input || typeof input !== "object" || Array.isArray(input)) invalid("request");
  const r = input as Record<string, unknown>;
  for (const key of Object.keys(r)) if (!["moduleId", "goals", "profiles", "skipTests", "offline", "alsoMake", "mavenProjectId"].includes(key)) invalid(key);
  if (r.mavenProjectId !== undefined && typeof r.mavenProjectId !== "string") invalid("mavenProjectId");
  if (typeof r.moduleId !== "string" || !model.modules.some(m => m.id === r.moduleId && !m.error)) invalid("moduleId");
  if (!Array.isArray(r.goals) || !r.goals.length || r.goals.some(g => typeof g !== "string" || g.startsWith("-") || !/^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+){0,3}(@[A-Za-z0-9_.-]+)?$/.test(g))) invalid("goals");
  if (r.profiles !== undefined && (!Array.isArray(r.profiles) || r.profiles.some(p => typeof p !== "string" || !/^!?[A-Za-z0-9_.-]+$/.test(p)))) invalid("profiles");
  for (const key of ["skipTests", "offline", "alsoMake"]) if (r[key] !== undefined && typeof r[key] !== "boolean") invalid(key);
  const request = structuredClone(r) as unknown as MavenRunRequest;
  const command = [model.executable === "wrapper" ? "./mvnw" : "mvn"];
  if (request.moduleId !== ".") { command.push("-pl", request.moduleId); if (request.alsoMake) command.push("-am"); }
  if (request.skipTests) command.push("-DskipTests");
  if (request.offline) command.push("-o");
  if (request.profiles?.length) command.push(`-P${request.profiles.join(",")}`);
  command.push(...request.goals);
  return { request, command };
}
