import { existsSync } from "node:fs";
import { spawn } from "node:child_process";
const mode = process.argv[2] || "normal";
if (mode === "exit-on-file")
  setInterval(() => { if (existsSync("exit-now")) process.exit(1); }, 25);
if (mode === "exit0") process.exit(0);
if (mode === "exit1") process.exit(1);
if (mode === "ignore" || mode === "ignore-silent" || mode === "tree-ignore") process.on("SIGTERM", () => {});
if (mode === "slowstop")
  process.on("SIGTERM", () => {
    setTimeout(() => process.exit(0), 1000);
  });
if (mode === "tree" || mode === "tree-ignore") {
  spawn(process.execPath, [import.meta.filename, "branch"], {
    stdio: "inherit",
  });
}
if (mode === "branch") {
  spawn(process.execPath, [import.meta.filename, "leaf"], {
    detached: true,
    stdio: "inherit",
  });
}
if (mode === "flood") {
  let i = 0;
  setInterval(() => {
    for (let n = 0; n < 200; n++)
      process.stdout.write(`${i++} ${"x".repeat(1000)}\n`);
  }, 5);
} else if (mode === "long") {
  process.stdout.write("界".repeat(40000) + "\n");
} else if (mode === "stderr") {
  setInterval(() => process.stderr.write("stderr-only\n"), 50);
} else if (mode === "ansi") {
  setInterval(() => process.stdout.write("\x1b[31mred\x1b[0m\n"), 50);
} else if (mode === "secret") {
  setInterval(
    () => process.stdout.write(`token=${process.env.TEST_TOKEN}\n`),
    50,
  );
} else if (mode !== "silent" && mode !== "ignore-silent") {
  setInterval(() => process.stdout.write(`${mode} pid=${process.pid}\n`), 50);
}
setInterval(() => {}, 1000);
