import { targetIssues } from "./project-targets.ts";
import { readyIssues } from "./ready.ts";
import { accessSync, constants, realpathSync, statSync } from "node:fs";
import { isAbsolute, resolve, delimiter } from "node:path";
import type {
  ProjectConfig,
  EnvMap,
  ValidateResult,
  ValidationIssue,
  ServiceResolution,
} from "@devpanel/contract";
import {
  onlySecretReferences,
  expandService,
  paramIssues,
  uses,
  formatValue,
} from "./params.ts";
import { Fault } from "./storage.ts";

export type BaseEnv = Record<string, string>;
export function baseEnvironment(): BaseEnv {
  const env: BaseEnv = {};
  for (const key of [
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "TMPDIR",
    "LANG",
    "PATH",
  ])
    if (process.env[key]) env[key] = process.env[key]!;
  env.PATH ||= "/usr/bin:/bin:/usr/sbin:/sbin";
  return env;
}
export function effectiveEnv(base: BaseEnv, ...maps: (EnvMap | undefined)[]) {
  const env = { ...base };
  for (const map of maps)
    for (const [key, value] of Object.entries(map || {}))
      env[key] = typeof value === "string" ? value : value.value || "";
  return env;
}
export function secrets(config: ProjectConfig) {
  return [
    ...(config.params || []).flatMap((p) =>
      p.secret && p.value !== undefined ? [formatValue(p.value)] : [],
    ),
    ...[config.env, ...[...config.services, ...(config.actions || [])].map((s) => s.env)].flatMap((m) =>
      Object.values(m || {}).flatMap((v) =>
        typeof v !== "string" && v.value ? [v.value] : [],
      ),
    ),
  ].filter(Boolean);
}
/** Generic responses avoid short-substring collisions; logs opt into strict matching. */
export function redact<T>(
  value: T,
  sensitive: string[],
  minSubstringLength = 8,
): T {
  const values = [...new Set(sensitive.filter(Boolean))];
  const exact = new Set(values);
  const fragments = values
    .filter((s) => [...s].length >= minSubstringLength)
    .sort((a, b) => b.length - a.length);
  // One pass prevents a later secret from changing an inserted [REDACTED] marker.
  const pattern = fragments.length
    ? new RegExp(
        fragments
          .map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
          .join("|"),
        "g",
      )
    : null;
  const clean = (v: unknown): unknown => {
    if (typeof v === "string") {
      if (exact.has(v)) return "[REDACTED]";
      return pattern ? v.replace(pattern, "[REDACTED]") : v;
    }
    if (Array.isArray(v)) return v.map(clean);
    if (v && typeof v === "object")
      return Object.fromEntries(
        Object.entries(v).map(([k, x]) => [k, clean(x)]),
      );
    return v;
  };
  return clean(value) as T;
}
export function mask(config: ProjectConfig): ProjectConfig {
  const c = structuredClone(config);
  for (const env of [c.env, ...[...c.services, ...(c.actions || [])].map((s) => s.env)])
    for (const key of Object.keys(env || {}))
      if (typeof env![key] !== "string") env![key] = { secret: true };
  for (const p of c.params || []) {
    if (p.secret) delete p.value;
    p.usedBy = uses(config, p.key);
  }
  return redact(c, secrets(config));
}
export function findProgram(
  program: string,
  cwd: string,
  path: string,
): string | null {
  const candidates = program.includes("/")
    ? [resolve(cwd, program)]
    : path.split(delimiter).map((p) => resolve(cwd, p || ".", program));
  for (const p of candidates) {
    try {
      accessSync(p, constants.X_OK);
      if (statSync(p).isFile()) return p;
    } catch {}
  }
  return null;
}
function directory(p: string) {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}
function object(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === "object" && !Array.isArray(v);
}
function str(v: unknown): v is string {
  return typeof v === "string" && v.length > 0 && !v.includes("\0");
}
export function validate(
  input: unknown,
  base: BaseEnv,
  previous?: ProjectConfig,
  mode: "validate" | "save" = "validate",
): ValidateResult {
  const issues: ValidationIssue[] = [],
    services: ServiceResolution[] = [];
  const issue = (
    path: string,
    message: string,
    code: ValidationIssue["code"] = "CONFIG_INVALID",
    severity: "error" | "warning" = "error",
  ) => issues.push({ path, message, code, severity });
  if (!object(input))
    return {
      ok: false,
      issues: [
        {
          path: "",
          message: "配置必须是 JSON 对象",
          code: "CONFIG_INVALID",
          severity: "error",
        },
      ],
      services,
    };
  issues.push(...paramIssues(input, previous, mode === "save"), ...targetIssues(input));
  if (input.schemaVersion !== 1)
    issue("schemaVersion", "schemaVersion 必须为 1");
  if (!str(input.name)) issue("name", "请输入项目名称");
  const instance = input.instance;
  if (instance !== undefined && (!object(instance) || !['group', 'name'].every(key => typeof instance[key] === 'string' && instance[key].trim().length > 0 && [...instance[key]].length >= 1 && [...instance[key]].length <= 80 && !/[\p{Cc}\p{Zl}\p{Zp}]/u.test(instance[key])))) issue('instance', '实例分组和名称须为 1–80 字符单行文本');
  if (!str(input.root) || !isAbsolute(input.root) || !directory(input.root))
    issue("root", "根目录必须是存在的绝对目录", "CWD_UNAVAILABLE");
  const envCheck = (env: unknown, path: string, old?: EnvMap) => {
    if (env === undefined) return;
    if (!object(env)) {
      issue(path, "环境变量必须是对象");
      return;
    }
    for (const [key, value] of Object.entries(env)) {
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key))
        issue(`${path}.${key}`, "环境变量名称无效");
      if (typeof value === "string" && !value.includes("\0")) {
        if (
          /TOKEN|SECRET|PASSWORD|KEY/i.test(key) &&
          !onlySecretReferences(
            value,
            Array.isArray(input.params) ? input.params : [],
          )
        )
          issue(
            `${path}.${key}`,
            "建议将此环境变量标记为敏感值",
            "WARN_SECRET_LIKE_PLAIN",
            "warning",
          );
      } else if (
        !object(value) ||
        value.secret !== true ||
        (value.value !== undefined &&
          (typeof value.value !== "string" || value.value.includes("\0")))
      )
        issue(`${path}.${key}`, "环境变量值无效");
      else if (
        mode === "save" &&
        value.value === undefined &&
        (typeof old?.[key] !== "object" || old[key]?.value === undefined)
      )
        issue(`${path}.${key}`, "新敏感变量需要提供 value");
    }
  };
  envCheck(input.env, "env", previous?.env);
  if (!Array.isArray(input.services) || !input.services.length)
    issue("services", "至少配置一个服务");
  for (const scope of ["services", "actions"] as const) {
    if (scope === "actions" && input.actions === undefined) continue;
    if (!Array.isArray(input[scope])) {
      if (scope === "actions") issue("actions", "快捷操作必须为数组");
      continue;
    }
    const seen = new Set<string>();
    for (const [i, s] of input[scope].entries()) {
      const p = `${scope}[${i}]`;
      if (!object(s)) {
        issue(p, "服务必须是对象");
        continue;
      }
      if (
        typeof s.id !== "string" ||
        !/^[a-z][a-z0-9-]{0,31}$/.test(s.id) ||
        seen.has(s.id)
      )
        issue(`${p}.id`, "服务 ID 无效或重复");
      if (typeof s.id === "string") seen.add(s.id);
      if (!str(s.name)) issue(`${p}.name`, "请输入服务名称");
      if (!str(s.cwd)) issue(`${p}.cwd`, "请输入工作目录");
      if (
        s.stopTimeoutSec !== undefined &&
        (typeof s.stopTimeoutSec !== "number" ||
          !Number.isFinite(s.stopTimeoutSec) ||
          s.stopTimeoutSec < 1 ||
          s.stopTimeoutSec > 300)
      )
        issue(`${p}.stopTimeoutSec`, "停止超时必须在 1–300 秒");
      if (scope === "actions") {
        if (s.timeoutSec !== undefined && (typeof s.timeoutSec !== "number" || !Number.isFinite(s.timeoutSec) || s.timeoutSec < 1 || s.timeoutSec > 86400)) issue(`${p}.timeoutSec`, "最长运行时间必须在 1–86400 秒");
        if (s.description !== undefined && typeof s.description !== "string") issue(`${p}.description`, "说明必须为文本");
        if (s.confirmWhenServicesRunning !== undefined && typeof s.confirmWhenServicesRunning !== "boolean") issue(`${p}.confirmWhenServicesRunning`, "确认开关必须为布尔值");
      }
      if (scope === "services" && s.ready !== undefined) issues.push(...readyIssues(s.ready, { params: input.params as any }, `${p}.ready`));
      envCheck(
        s.env,
        `${p}.env`,
        previous?.[scope]?.find((x) => x.id === s.id)?.env,
      );
      if (
        !Array.isArray(s.command) ||
        !s.command.length ||
        !s.command.every(
          (x: unknown) => typeof x === "string" && !x.includes("\0"),
        ) ||
        !str(s.command[0])
      ) {
        issue(`${p}.command`, "command 必须是非空 argv 数组");
        continue;
      }
      if (!str(s.cwd) || !str(input.root)) continue;
      const cwdAbs = resolve(input.root, s.cwd),
        cwdExists = directory(cwdAbs);
      if (!cwdExists) issue(`${p}.cwd`, "工作目录不存在", "CWD_UNAVAILABLE");
      let env = base;
      let unknownPath = false;
      let unknownProgram = false;
      let program = s.command[0] as string;
      if (!issues.some((x) => x.severity === "error")) {
        const resolved = resolveSecrets(
          input as unknown as ProjectConfig,
          previous,
          // envCheck reports missing saved values per scope; do not throw while
          // resolving another service that has not been validated yet.
          true,
        );
        const expanded = expandService(resolved, resolved[scope]![i]!);
        program = expanded.command[0]!;
        const path = expanded.env?.PATH;
        unknownPath = typeof path === "object" && path.value === undefined;
        env = effectiveEnv(base, expanded.env);
        const missing =
          resolved.params?.filter((p) => p.secret && p.value === undefined) ||
          [];
        unknownProgram = missing.some((p) =>
          program.includes("${" + p.key + "}"),
        );
        if (
          missing.some(
            (p) =>
              typeof path === "string" && path.includes("${" + p.key + "}"),
          )
        ) {
          unknownPath = true;
          env.PATH = "";
        }
      }
      const pathUsed = env.PATH || "",
        // Standalone validation cannot resolve a masked PATH until save supplies its value.
        canResolve = !unknownProgram && (!unknownPath || program.includes("/")),
        programResolved = canResolve
          ? findProgram(program, cwdAbs, pathUsed)
          : null;
      if (canResolve && !programResolved)
        issue(
          `${p}.command[0]`,
          "在有效 PATH 中找不到可执行程序",
          "COMMAND_NOT_FOUND",
        );
      services.push({
        serviceId: scope === "actions" ? `action:${s.id}` : String(s.id),
        cwdAbs,
        cwdExists,
        program: s.command[0] as string,
        programResolved,
        pathUsed,
      });
      const text = s.command.join(" ");
      if (
        /\bnohup\b|(?:^|\s)&(?:\s|$)|\b(?:docker|podman)\b.*(?:-d|--detach)/.test(
          text,
        )
      )
        issue(
          `${p}.command`,
          "请使用前台运行方式",
          "WARN_BACKGROUND_COMMAND",
          "warning",
        );
      if (/[;|]|&&/.test(text))
        issue(
          `${p}.command`,
          "Shell 复合命令建议拆为多个服务",
          "WARN_SHELL_COMPOUND",
          "warning",
        );
    }
  }
  if (input.maven !== undefined && (!object(input.maven) || (input.maven.executable !== undefined && !["auto", "wrapper", "mvn"].includes(String(input.maven.executable))))) issue("maven.executable", "Maven 可执行文件选择无效");
  // Validation responses may contain PATH, which can itself be marked secret.
  const values: string[] = Array.isArray(input.params)
    ? input.params.flatMap((p) =>
        p?.secret && ["string", "number", "boolean"].includes(typeof p.value)
          ? [formatValue(p.value)]
          : [],
      )
    : [];
  for (const env of [
    input.env,
    ...(Array.isArray(input.actions) ? input.actions.filter(object).map(s => s.env) : []),
    ...(Array.isArray(input.services)
      ? input.services.filter(object).map((s) => s.env)
      : []),
  ])
    if (object(env))
      for (const v of Object.values(env))
        if (
          object(v) &&
          v.secret === true &&
          typeof v.value === "string" &&
          v.value
        )
          values.push(v.value);
  return redact(
    { ok: !issues.some((x) => x.severity === "error"), issues, services },
    [...values, ...(previous ? secrets(previous) : [])],
  );
}
export function resolveSecrets(
  config: ProjectConfig,
  previous?: ProjectConfig,
  allowUnresolved = false,
): ProjectConfig {
  const c = structuredClone(config);
  const merge = (env?: EnvMap, old?: EnvMap) => {
    for (const [key, v] of Object.entries(env || {}))
      if (typeof v !== "string" && v.value === undefined) {
        const prev = old?.[key];
        if (typeof prev !== "object" || prev.value === undefined) {
          if (allowUnresolved) continue;
          throw new Fault("CONFIG_INVALID", "新敏感变量需要提供 value", 422);
        }
        env![key] = structuredClone(prev);
      }
  };
  merge(c.env, previous?.env);
  for (const s of c.services)
    merge(s.env, previous?.services.find((x) => x.id === s.id)?.env);
  for (const a of c.actions || []) merge(a.env, previous?.actions?.find(x => x.id === a.id)?.env);
  for (const p of c.params || [])
    if (p.secret && p.value === undefined) {
      const old = previous?.params?.find((x) => x.key === p.key && x.secret);
      if (old?.value !== undefined) p.value = old.value;
      else if (!allowUnresolved)
        throw new Fault("CONFIG_INVALID", "新敏感选项需要提供 value", 422);
    }
  c.root = realpathSync(c.root);
  return c;
}
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  if (object(value))
    return (
      "{" +
      Object.keys(value)
        .sort()
        .map((k) => JSON.stringify(k) + ":" + canonical(value[k]))
        .join(",") +
      "}"
    );
  return JSON.stringify(value);
}
