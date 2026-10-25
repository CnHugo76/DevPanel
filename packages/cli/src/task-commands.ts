import type { StartTaskRunResponse, TaskRunSummary } from "@devpanel/contract";
import { api, raw, ClientError } from "./client.ts";

export async function waitTask(start: StartTaskRunResponse, options: { noWait?: boolean; follow?: boolean; timeout: number; json: boolean }) {
  if (options.noWait) return { value: start, code: 0 };
  let run = start.run;
  const until = Date.now() + options.timeout * 1000;
  const output = options.json ? process.stderr : process.stdout;
  const stream = options.follow ? await raw(`/runs/${run.id}/logs/stream?afterSeq=0`) : null;
  if (stream && (stream.statusCode ?? 500) >= 400) {
    stream.resume();
    throw new ClientError({ error: { code: "RUN_NOT_FOUND", message: "无法订阅任务日志" } });
  }
  let streamError: unknown;
  const flowing = stream ? (async () => {
    stream.setTimeout(0); stream.setEncoding("utf8");
    let pending = "";
    for await (const chunk of stream) {
      pending += chunk;
      let end: number;
      while ((end = pending.indexOf("\n\n")) >= 0) {
        const block = pending.slice(0, end); pending = pending.slice(end + 2);
        const data = block.split("\n").find(l => l.startsWith("data: "));
        if (!data) continue;
        const event = JSON.parse(data.slice(6));
        if (event.type === "lines") for (const line of event.lines) output.write(line.text + "\n");
        if (event.type === "gap" || event.type === "truncated") process.stderr.write("日志有缺口或已截断\n");
      }
    }
  })().catch(e => { streamError = e; }) : Promise.resolve();
  try {
    while (!run.endedAt && Date.now() < until) {
      await new Promise(resolve => setTimeout(resolve, 100));
      run = await api<TaskRunSummary>(`/task-runs/${run.id}`);
    }
    if (run.endedAt) {
      let timer: NodeJS.Timeout | undefined;
      await Promise.race([flowing, new Promise(resolve => { timer = setTimeout(resolve, 1000); })]);
      clearTimeout(timer);
    }
    if (streamError && !run.endedAt) throw streamError;
    return { value: run, code: !run.endedAt ? 8 : run.state === "succeeded" ? 0 : run.state === "cancelled" ? 9 : 1 };
  } finally { stream?.destroy(); await flowing; }
}
