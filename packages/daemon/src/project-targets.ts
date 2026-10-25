import { existsSync, realpathSync, statSync } from "node:fs";
import { isAbsolute, join, relative, resolve } from "node:path";
import type { MavenProjectConfig, ProjectConfig, RepositoryConfig, ValidationIssue } from "@devpanel/contract";
import { Fault } from "./storage.ts";

export function targetDirectory(root: string, path: string): string {
  if (!path || isAbsolute(path) || path.includes("\0") || path.includes("${") || path.split("/").includes(".."))
    throw new Error("目标目录须为项目内的相对路径");
  const base = realpathSync(root), actual = realpathSync(resolve(base, path)), rel = relative(base, actual);
  if (isAbsolute(rel) || rel === ".." || rel.startsWith("../") || !statSync(actual).isDirectory())
    throw new Error("目标目录不在项目内或不是目录");
  return actual;
}

/** Filesystem checks only. Saving configuration never invokes Git, Maven or project commands. */
export function targetIssues(input: Record<string, unknown>): ValidationIssue[] {
  const issues: ValidationIssue[] = [];
  const error = (path: string, message: string) => issues.push({ path, message, severity: "error", code: "CONFIG_INVALID" });
  for (const key of ["repositories", "mavenProjects"] as const) {
    const values = input[key];
    if (values === undefined) continue;
    if (!Array.isArray(values) || values.length > 32) { error(key, "目标必须为数组，最多 32 项"); continue; }
    const ids = new Set<string>(), paths = new Set<string>();
    values.forEach((value, i) => {
      const path = `${key}[${i}]`;
      if (!value || typeof value !== "object" || Array.isArray(value)) { error(path, "目标必须为对象"); return; }
      const target = value as Record<string, unknown>;
      if (Object.keys(target).some(k => !["id", "name", "path", ...(key === "mavenProjects" ? ["executable"] : [])].includes(k))) error(path, "目标含未知字段");
      if (typeof target.id !== "string" || !/^[a-z][a-z0-9-]{0,31}$/.test(target.id) || ids.has(target.id)) error(`${path}.id`, "目标 ID 无效或重复");
      else ids.add(target.id);
      if (typeof target.name !== "string" || !target.name.trim() || target.name.length > 80 || target.name.includes("\0")) error(`${path}.name`, "请输入 1–80 字符名称");
      if (key === "mavenProjects" && target.executable !== undefined && !["auto", "wrapper", "mvn"].includes(String(target.executable))) error(`${path}.executable`, "Maven 可执行文件选择无效");
      try {
        if (typeof input.root !== "string" || typeof target.path !== "string") throw new Error("目标目录必须为相对路径");
        const root = targetDirectory(input.root, target.path);
        if (paths.has(root)) throw new Error("目标真实目录重复");
        paths.add(root);
        const marker = join(root, key === "repositories" ? ".git" : "pom.xml");
        if (!existsSync(marker)) throw new Error(key === "repositories" ? "目录中没有 .git（须登记工作树根）" : "目录中没有 pom.xml");
        if (key === "mavenProjects") {
          const pom = realpathSync(marker), rel = relative(realpathSync(input.root), pom);
          if (rel.startsWith("../") || isAbsolute(rel) || !statSync(pom).isFile()) throw new Error("POM 不在项目内或不是文件");
        }
      } catch (e) { error(`${path}.path`, e instanceof Error ? e.message : "目标目录不可用"); }
    });
  }
  return issues;
}

function selected<T extends RepositoryConfig>(list: T[], id: string | undefined): T {
  const target = id === undefined && list.length === 1 ? list[0] : list.find(x => x.id === id);
  if (!target) throw new Fault("BAD_REQUEST", id === undefined ? "请明确选择已登记的目标 ID" : "目标 ID 未登记", 400);
  return target;
}
export function gitTarget(config: ProjectConfig, repositoryId?: string): string {
  if (config.repositories === undefined && repositoryId === undefined) return config.root;
  const target = selected(config.repositories ?? [], repositoryId);
  try {
    const root = targetDirectory(config.root, target.path);
    if (!existsSync(join(root, ".git"))) throw new Error("已登记仓库的 .git 不存在");
    return root;
  } catch { throw new Fault("GIT_FAILED", "已登记的 Git 仓库目录不可用", 422); }
}
export function mavenTarget(config: ProjectConfig, mavenProjectId?: string): { config: ProjectConfig; target?: MavenProjectConfig } {
  if (config.mavenProjects === undefined && mavenProjectId === undefined) return { config };
  const target = selected(config.mavenProjects ?? [], mavenProjectId);
  try {
    const root = targetDirectory(config.root, target.path);
    return { target, config: { ...config, root, maven: { executable: target.executable ?? "auto" } } };
  } catch { throw new Fault("MAVEN_UNAVAILABLE", "已登记的 Maven 工程目录不可用", 404); }
}
