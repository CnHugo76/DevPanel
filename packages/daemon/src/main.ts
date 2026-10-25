#!/usr/bin/env node
import { startServer } from "./server.ts";
import { homePath } from "./storage.ts";
const port = Number(process.env.DEVPANEL_PORT ?? 47823);
if (!Number.isInteger(port) || port < 0 || port > 65535) {
  process.stderr.write("DEVPANEL_PORT 必须是 0–65535 的整数\n");
  process.exit(2);
}
try {
  const server = await startServer(homePath(), port);
  // An external termination cannot promise a graceful shutdown. Persist identities and
  // exit without signaling business processes; next startup exposes the logging gap.
  const terminate = () => {
    void server.close().then(() => process.exit(0));
  };
  process.once("SIGTERM", terminate);
  process.once("SIGINT", terminate);
} catch (e) {
  process.stderr.write(
    `devpaneld: ${e instanceof Error ? e.message : "启动失败"}\n`,
  );
  process.exitCode = 1;
}
