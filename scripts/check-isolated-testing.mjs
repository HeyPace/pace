// Bridges the native power checks to Node-based verification runners.
// Native counts remain in test-pace.sh's authoritative xcresult summary.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

test("Pace isolated testing power passes its native checks", { timeout: 120000 }, () => {
  const runner = fileURLToPath(new URL("./test-pace.sh", import.meta.url));
  const result = spawnSync("bash", [runner,
    "PaceSkillLoaderTests", "PaceMCPServerCatalogTests", "PaceMCPClientIntegrationTests",
  ], { stdio: "inherit", timeout: 115000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, "Native checks failed; inspect the xcresult and last-build.log");
});
