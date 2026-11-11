// Repeatable native verification for the isolated testing power.
// Uses the TCC-preserving runner; its xcresult summary requires executed tests.
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const runner = fileURLToPath(new URL("./test-pace.sh", import.meta.url));
const result = spawnSync("bash", [runner,
  "PaceSkillLoaderTests", "PaceMCPServerCatalogTests", "PaceMCPClientIntegrationTests",
], { stdio: "inherit" });
if (result.error) console.error(result.error.message);
process.exit(result.status ?? 1);
