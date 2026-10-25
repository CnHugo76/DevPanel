import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm, chmod, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { MavenModels, mavenCommand, mavenExecutable } from "../src/maven.ts";
import { cleanupTaskServer } from "./helpers/cleanup.ts";
import { startServer } from "../src/server.ts";
import { sleep } from "../src/storage.ts";
import type { ProjectConfig } from "@devpanel/contract";
const exec = promisify(execFile);
const cli = resolve(import.meta.dirname, "../../cli/src/main.ts");
async function fixture(t: any, cleanup = true) {
  const root = await mkdtemp(join(tmpdir(), "dp-mvn-"));
  if (cleanup) t.after(() => rm(root, { recursive: true, force: true }));
  const pom = async (dir: string, body: string) => { await mkdir(join(root, dir), { recursive: true }); await writeFile(join(root, dir, "pom.xml"), `<project>${body}</project>`); };
  await pom(".", '<groupId>dev.test</groupId><artifactId>root</artifactId><packaging>pom</packaging><modules><module>backend</module><module>broken</module><module>external</module></modules><profiles><profile><id>dev</id></profile></profiles>');
  await pom("backend", '<parent><groupId>dev.test</groupId><artifactId>root</artifactId></parent><artifactId>backend</artifactId><modules><module>nested</module></modules><profiles><profile><id>dev</id></profile><profile><id>prod</id></profile></profiles>');
  await pom("backend/nested", '<artifactId>nested</artifactId><name>嵌套模块</name>');
  await pom("external", '<parent><groupId>outside</groupId><relativePath/></parent><artifactId>external</artifactId>');
  await pom("broken", '<artifactId>broken');
  await writeFile(join(root, "mvnw"), `#!${process.execPath}\nconsole.log(JSON.stringify(process.argv.slice(2)));console.log(process.env.JAVA_HOME);setTimeout(()=>process.exit(process.argv.includes('fail')?1:0),300);\n`, { mode: 0o755 });
  const config: ProjectConfig = { schemaVersion: 1, name: "Maven fixture", root, services: [{ id: "maven", name: "service named maven", cwd: ".", command: [process.execPath, "-e", "process.exit(0)"] }], env: { JAVA_HOME: "/fake/java" } };
  return { root, pom, config };
}
test("static nested model, inherited group, default packaging, external parent, per-module errors and mtime cache", async t => {
  const f = await fixture(t); const models = new MavenModels();
  const m = models.read(f.config, {});
  assert.deepEqual(m.modules.map(m => m.id), [".", "backend", "backend/nested", "broken", "external"]);
  assert.equal(m.modules[1]!.groupId, "dev.test"); assert.equal(m.modules[2]!.packaging, "jar");
  assert.equal(m.modules[1]!.parentOutside, false); assert.equal(m.modules[4]!.parentOutside, true);
  assert.ok(m.modules[3]!.error); assert.deepEqual(m.profiles, ["dev", "prod"]);
  assert.equal(models.read(f.config, {}).scannedAt, m.scannedAt);
  await sleep(5); await f.pom("backend/nested", '<artifactId>changed</artifactId>');
  assert.equal(models.read(f.config, {}).modules[2]!.artifactId, "changed");
  await sleep(5); assert.notEqual(models.read(f.config, {}, true).scannedAt, m.scannedAt);
  await f.pom(".", '<artifactId>root</artifactId><modules><module>loop</module><module>../outside</module></modules>');
  await symlink(f.root, join(f.root, "loop"));
  // Symlink cycles must terminate, and outside POMs must not be read.
  const bounded = models.read(f.config, {}, true);
  assert.ok(bounded.modules.length < 10);
  assert.ok(bounded.modules.at(-1)!.error);
});
test("Maven executable modes, strict argv construction and unsafe request rejection", async t => {
  const f = await fixture(t); const models = new MavenModels(); const model = models.read(f.config, {});
  assert.equal(model.executable, "wrapper");
  const request = { moduleId: "backend", goals: ["clean", "install"], profiles: ["dev", "!prod"], skipTests: true, offline: true, alsoMake: true };
  assert.deepEqual(mavenCommand(request, model).command, ["./mvnw", "-pl", "backend", "-am", "-DskipTests", "-o", "-Pdev,!prod", "clean", "install"]);
  assert.deepEqual(mavenCommand({ ...request, moduleId: "." }, model).command.slice(0, 2), ["./mvnw", "-DskipTests"]);
  for (const patch of [{ moduleId: "../x" }, { goals: [] }, { goals: ["install;touch"] }, { goals: ["-o"] }, { profiles: ["x,y"] }, { offline: "true" }, { extra: true }])
    assert.throws(() => mavenCommand({ ...request, ...patch }, model), (e: any) => e.error.code === "MAVEN_INVALID");
  await chmod(join(f.root, "mvnw"), 0o644);
  assert.throws(() => mavenExecutable(f.config, { PATH: f.root }), (e: any) => e.error.code === "COMMAND_NOT_FOUND");
  await writeFile(join(f.root, "mvn"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  f.config.env = { PATH: f.root };
  assert.equal(mavenExecutable(f.config, {}).executable, "mvn");
  f.config.maven = { executable: "wrapper" };
  assert.throws(() => mavenExecutable(f.config, {}), (e: any) => e.error.code === "COMMAND_NOT_FOUND");
});
test("Maven uses shared tasks: busy rejection, project env, history, cancellation, CLI and no registration execution", async t => {
  const f = await fixture(t, false); const server = await startServer(join(f.root, "home"), 0); const m = server.manager;
  t.after(() => cleanupTaskServer(server, f.root));
  const p = m.register(f.config).project; assert.equal(m.runs.size, 0); assert.ok(m.view(p.id).maven);
  const ends = async (id: string) => { for (let i = 0; i < 200; i++) { await m.refresh(); if (m.taskDetail(id).endedAt) return m.taskDetail(id); await sleep(25); } throw Error("timeout"); };
  const run = await m.startMaven(p.id, { moduleId: "backend", goals: ["install"] }, { client: "cli", agent: null });
  assert.equal(m.view(p.id).services[0]!.currentRun, null);
  await assert.rejects(m.startMaven(p.id, { moduleId: ".", goals: ["clean"] }, { client: "ui", agent: null }), (e: any) => e.error.code === "TASK_RUNNING" && e.error.details.runId === run.run.id);
  assert.equal((await ends(run.run.id)).state, "succeeded");
  assert.ok(JSON.stringify(m.logs.page(run.run.id, new URLSearchParams(), true)).includes("/fake/java"));
  const command = (...args: string[]) => exec(process.execPath, [cli, ...args], { env: { ...process.env, DEVPANEL_HOME: join(f.root, "home") } });
  assert.equal(JSON.parse((await command("maven", "modules", p.id, "--json")).stdout).modules.length, 5);
  const result = JSON.parse((await command("maven", "run", p.id, "--module", "backend", "-P", "dev", "--skip-tests", "install", "--follow", "--json")).stdout);
  assert.equal(result.state, "succeeded");
  await assert.rejects(command("maven", "run", p.id, "fail", "--json"), (e: any) => e.code === 1);
  const lastFinished = m.view(p.id).maven!.lastRun!.id;
  const cancel = await m.startMaven(p.id, { moduleId: ".", goals: ["install"] }, { client: "ui", agent: null });
  assert.equal(m.view(p.id).maven!.lastRun!.id, lastFinished);
  assert.equal(m.view(p.id).maven!.currentRun!.id, cancel.run.id);
  await m.cancelTask(cancel.run.id, true); assert.equal((await ends(cancel.run.id)).state, "cancelled");
  assert.equal(m.taskHistory(p.id, { kind: "maven" }).length, 4);
});

test("missing POM availability and later-created module invalidate the cache", async t => {
  const f = await fixture(t); const models = new MavenModels();
  await f.pom(".", '<artifactId>root</artifactId><modules><module>later</module></modules>');
  assert.ok(models.read(f.config, {}).modules[1]!.error);
  await f.pom("later", '<artifactId>created</artifactId>');
  assert.equal(models.read(f.config, {}).modules[1]!.error, null);
  await rm(join(f.root, "pom.xml"));
  assert.throws(() => models.read(f.config, {}), (e: any) => e.error.code === "MAVEN_UNAVAILABLE" && e.status === 404);
});
