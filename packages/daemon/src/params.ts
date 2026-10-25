import { basename } from "node:path";
import type {
  ClientKind,
  EnvMap,
  ParamConfig,
  ParamReference,
  ParamValue,
  ProjectConfig,
  ServiceConfig,
  ActionConfig,
  ValidationIssue,
} from "@devpanel/contract";
import { Fault, now } from "./storage.ts";

const token = /\$\$\{|\$\{([a-zA-Z][a-zA-Z0-9_]{0,31})\}/g;
export function references(text: string): string[] {
  return [...text.matchAll(token)].flatMap((m) =>
    m[1] === undefined ? [] : [m[1]],
  );
}
/** Only references in the effective service environment count toward its run. */
export function serviceParams(config: ProjectConfig, service: ServiceConfig) {
  const values = [
    ...service.command,
    ...Object.values({ ...config.env, ...service.env }).filter(
      (v): v is string => typeof v === "string",
    ),
  ];
  const keys = new Set(values.flatMap(references));
  return (config.params || []).filter((p) => keys.has(p.key));
}
export function onlySecretReferences(value: string, params: ParamConfig[]) {
  const keys = references(value);
  return (
    keys.length > 0 &&
    value.replace(token, "") === "" &&
    [...value.matchAll(token)].every((m) => m[1] !== undefined) &&
    keys.every((key) => params.some((p) => p?.key === key && p.secret === true))
  );
}
export function uses(config: ProjectConfig, key: string): ParamReference[] {
  const result: ParamReference[] = [];
  const env = (map: EnvMap | undefined, serviceId: string) => {
    for (const [envKey, v] of Object.entries(map || {}))
      if (typeof v === "string" && references(v).includes(key))
        result.push({ serviceId, where: "env", envKey });
  };
  env(config.env, "*");
  for (const s of [...config.services, ...(config.actions || []).map(a => ({ ...a, id: `action:${a.id}` }))]) {
    s.command.forEach((v, index) => {
      if (references(v).includes(key))
        result.push({ serviceId: s.id, where: "command", index });
    });
    env(s.env, s.id);
    if (readyPortReference(s, key)) result.push({ serviceId: s.id, where: "ready" });
  }
  return result;
}
export function formatValue(value: ParamValue): string {
  if (typeof value !== "number" || !String(value).includes("e"))
    return String(value);
  const [mantissa, exp] = String(value).split("e");
  const negative = mantissa!.startsWith("-");
  const parts = mantissa!.replace("-", "").split(".");
  const digits = parts.join("");
  const point = parts[0]!.length + Number(exp);
  return (
    (negative ? "-" : "") +
    (point <= 0
      ? "0." + "0".repeat(-point) + digits
      : point >= digits.length
        ? digits + "0".repeat(point - digits.length)
        : digits.slice(0, point) + "." + digits.slice(point))
  );
}
const quote = (v: string) => "'" + v.replaceAll("'", "'\\''") + "'";
export function scriptIndex(command: string[]) {
  if (!["sh", "bash", "zsh"].includes(basename(command[0]!))) return -1;
  const i = command.findIndex((v, i) => i > 0 && /^-[a-zA-Z]*c$/.test(v));
  return i < 0 ? -1 : i + 1;
}
/** One pass: inserted values are never interpreted as templates. Preserve shell quote context. */
export function substitute(
  text: string,
  params: ParamConfig[],
  shell = false,
  masked = false,
  only?: string,
): string {
  let context = "",
    escaped = false,
    cursor = 0;
  const scan = (part: string) => {
    for (const c of part) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c === "\\" && context !== "'") {
        escaped = true;
        continue;
      }
      if (c === context) context = "";
      else if (!context && (c === "'" || c === '"')) context = c;
    }
  };
  return text.replace(
    token,
    (match: string, key: string | undefined, offset: number) => {
      scan(text.slice(cursor, offset));
      cursor = offset + match.length;
      if (key === undefined) return only ? match : "${";
      if (only && key !== only) return match;
      const param = params.find((p) => p.key === key);
      if (!param || param.value === undefined) return match;
      let value = masked && param.secret ? "••••" : formatValue(param.value);
      if (shell)
        value = context ? context + quote(value) + context : quote(value);
      // Inlined config remains a template until the next start.
      return only ? value.replaceAll("${", () => "$${") : value;
    },
  );
}
export function expandService(
  config: ProjectConfig,
  service: ServiceConfig,
  masked = false,
): ServiceConfig {
  const params = config.params || [];
  const script = scriptIndex(service.command.map((v) => substitute(v, params)));
  const env = { ...config.env, ...service.env };
  for (const [key, v] of Object.entries(env))
    if (typeof v === "string") env[key] = substitute(v, params, false, masked);
  return {
    ...service,
    env,
    command: service.command.map((v, i) =>
      substitute(v, params, i === script, masked),
    ),
  };
}
export function paramIssues(
  input: Record<string, unknown>,
  previous?: ProjectConfig,
  save = false,
): ValidationIssue[] {
  const issues: ValidationIssue[] = [];
  const add = (
    path: string,
    message: string,
    code: ValidationIssue["code"] = "PARAM_INVALID",
    severity: "error" | "warning" = "error",
  ) => issues.push({ path, message, code, severity });
  if (input.params !== undefined && !Array.isArray(input.params)) {
    add("params", "选项必须为数组");
    return issues;
  }
  const params = (input.params || []) as ParamConfig[];
  const keys = new Set<string>();
  for (const [i, p] of params.entries()) {
    const path = `params[${i}]`;
    if (!p || typeof p !== "object" || Array.isArray(p)) {
      add(path, "选项必须为对象");
      continue;
    }
    if (
      typeof p.key !== "string" ||
      !/^[a-zA-Z][a-zA-Z0-9_]{0,31}$/.test(p.key) ||
      keys.has(p.key)
    )
      add(path + ".key", "选项 key 无效或重复");
    keys.add(p.key);
    if (typeof p.label !== "string" || !p.label || p.label.includes("\0"))
      add(path + ".label", "请输入选项名称");
    if (p.description !== undefined && typeof p.description !== "string")
      add(path + ".description", "说明必须为文本");
    if (p.secret !== undefined && typeof p.secret !== "boolean")
      add(path + ".secret", "secret 必须为布尔值");
    if (!["string", "number", "boolean", "enum"].includes(p.type))
      add(path + ".type", "选项类型无效");
    if (p.choices !== undefined && p.type !== "enum")
      add(path + ".choices", "仅单选支持 choices");
    if (
      p.type === "enum" &&
      (!Array.isArray(p.choices) ||
        !p.choices.length ||
        p.choices.some(
          (c) =>
            !c ||
            typeof c.value !== "string" ||
            c.value.includes("\0") ||
            (c.label !== undefined && typeof c.label !== "string") ||
            (c.description !== undefined && typeof c.description !== "string"),
        ))
    )
      add(path + ".choices", "单选需要有效 choices");
    for (const field of ["min", "max"] as const)
      if (
        p[field] !== undefined &&
        (p.type !== "number" ||
          typeof p[field] !== "number" ||
          !Number.isFinite(p[field]))
      )
        add(path + "." + field, "范围必须为有限数字");
    if (p.min !== undefined && p.max !== undefined && p.min > p.max)
      add(path, "min 不得大于 max");
    const old = previous?.params?.find((x) => x.key === p.key && x.secret);
    const value = p.secret && p.value === undefined ? old?.value : p.value;
    if (p.secret && value === undefined && !save) continue;
    if (
      (p.type === "number"
        ? typeof value !== "number" || !Number.isFinite(value)
        : p.type === "boolean"
          ? typeof value !== "boolean"
          : typeof value !== "string" || value.includes("\0")) ||
      (p.type === "enum" &&
        (!Array.isArray(p.choices) ||
          !p.choices.some((c) => c?.value === value))) ||
      (typeof value === "number" &&
        ((p.min !== undefined && value < p.min) ||
          (p.max !== undefined && value > p.max)))
    )
      add(path + ".value", "值不符合类型、可选值或范围");
  }
  const used = new Set<string>();
  const check = (value: unknown, path: string) => {
    if (typeof value === "string")
      for (const key of references(value)) {
        used.add(key);
        if (!keys.has(key)) add(path, "引用了未定义选项", "PARAM_UNKNOWN");
      }
  };
  const env = (value: unknown, path: string) => {
    if (value && typeof value === "object" && !Array.isArray(value))
      for (const [k, v] of Object.entries(value)) check(v, `${path}.${k}`);
  };
  env(input.env, "env");
  for (const scope of ["services", "actions"] as const)
  if (Array.isArray(input[scope]))
    input[scope].forEach((s, i) => {
      if (!s || typeof s !== "object") return;
      if (Array.isArray(s.command))
        s.command.forEach((v: unknown, j: number) =>
          check(v, `${scope}[${i}].command[${j}]`),
        );
      env(s.env, `${scope}[${i}].env`);
      if (scope === "services" && s.ready?.check?.kind === "port") check(s.ready.check.port, `${scope}[${i}].ready.check.port`);
    });
  params.forEach((p, i) => {
    if (p && typeof p.key === "string" && !used.has(p.key))
      add(`params[${i}]`, "选项未被引用", "WARN_PARAM_UNUSED", "warning");
  });
  return issues;
}
export function prepareParams(
  input: unknown,
  previous: ProjectConfig | undefined,
  client: ClientKind,
  protect: boolean,
) {
  const config = structuredClone(input) as ProjectConfig;
  const kept: string[] = [];
  if (!config || !Array.isArray(config.params)) return { config, kept };
  for (const p of config.params) {
    if (!p || typeof p !== "object") continue;
    const old = previous?.params?.find((x) => x.key === p.key);
    delete p.setBy;
    delete p.valueUpdatedAt;
    delete p.describedBy;
    delete p.usedBy;
    if (p.secret && p.value === undefined && old?.secret) p.value = old.value;
    if (protect && old?.setBy === "user" && p.value !== old.value) {
      p.value = old.value;
      if (old.secret) p.secret = true;
      kept.push(p.key);
    }
    const setter = client === "ui" ? "user" : "agent";
    p.setBy = old && old.value === p.value ? old.setBy : setter;
    p.valueUpdatedAt =
      old && old.value === p.value ? old.valueUpdatedAt : now();
    p.describedBy =
      old &&
      ["label", "description", "choices", "min", "max"].every(
        (k) =>
          JSON.stringify(old[k as keyof ParamConfig]) ===
          JSON.stringify(p[k as keyof ParamConfig]),
      )
        ? old.describedBy
        : setter;
  }
  return { config, kept };
}
/** Response-only option metadata never participates in config equivalence or diffs. */
export const PARAM_RESPONSE_KEYS = ["setBy", "valueUpdatedAt", "describedBy", "usedBy"] as const;
export function comparable<T>(config: T): T {
  const c = structuredClone(config);
  if (c && typeof c === "object" && "params" in c && Array.isArray(c.params)) {
    for (const param of c.params) if (param && typeof param === "object") {
      for (const key of PARAM_RESPONSE_KEYS) delete param[key];
    }
  }
  return c;
}
function readyPortReference(service: ServiceConfig | ActionConfig, key: string) {
  if ("ready" in service && service.ready?.check.kind === "port" && service.ready.check.port === "${" + key + "}") return service.ready.check;
  return undefined;
}
export function inlineParam(config: ProjectConfig, key: string) {
  const p = config.params!.find((p) => p.key === key)!;
  const refs = uses(config, key);
  if (p.secret && refs.some((r) => r.where === "command"))
    throw new Fault("PARAM_IN_USE", "敏感选项不能写回命令", 409, {
      reason: "secret",
      usedBy: refs,
    });
  const env = (map?: EnvMap) => {
    for (const [k, v] of Object.entries(map || {}))
      if (typeof v === "string" && references(v).includes(key))
        map![k] = p.secret
          ? { secret: true, value: substitute(v, config.params || []) }
          : substitute(v, config.params || [], false, false, key);
  };
  env(config.env);
  for (const s of [...config.services, ...(config.actions || [])]) {
    const script = scriptIndex(expandService(config, s).command);
    s.command = s.command.map((v, i) =>
      substitute(v, config.params || [], i === script, false, key),
    );
    env(s.env);
    const ready = readyPortReference(s, key);
    if (ready) ready.port = p.value as number;
  }
}
