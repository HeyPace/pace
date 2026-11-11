// Bridges native power checks; native counts remain in the xcresult summary.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

test("Pace isolated testing power passes its native checks", { timeout: 900000 }, async (t) => {
  const runner = fileURLToPath(new URL("./test-pace.sh", import.meta.url));
  const child = spawn("bash", [runner,
    "PaceSkillLoaderTests", "PaceMCPServerCatalogTests", "PaceMCPClientIntegrationTests",
  ], { stdio: "inherit", detached: true });
  const stop = () => {
    if (child.exitCode === null && child.pid) {
      try { process.kill(-child.pid, "SIGTERM"); } catch (error) {
        if (error.code !== "ESRCH") throw error;
      }
    }
  };
  t.signal.addEventListener("abort", stop, { once: true });
  process.once("SIGTERM", stop);
  try {
    const [status, signal] = await once(child, "exit");
    assert.equal(signal, null, "Native checks were interrupted");
    assert.equal(status, 0, "Native checks failed; inspect xcresult and last-build.log");
  } finally {
    process.removeListener("SIGTERM", stop);
    stop();
  }
});
