/** Always attempt daemon shutdown and identity audit even if stopping a project fails. */
export async function cleanupSmoke({ stopProject, stopDaemon, audit }) {
  const failures = [];
  try { await stopProject(); } catch (error) { failures.push(error); }
  try { await stopDaemon(); } catch (error) { failures.push(error); }
  try { await audit(); } catch (error) { failures.push(error); }
  if (failures.length) throw new AggregateError(failures, "发布包清理失败");
}

/** Validate before collecting output or writing any report. */
export function assertNoSecrets(value, secrets) {
  if (secrets.some(secret => JSON.stringify(value).includes(secret))) throw new Error("发布包输出含敏感值，未保存报告");
}
