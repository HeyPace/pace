import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repositoryRoot = fileURLToPath(new URL('../', import.meta.url));
const runnerPath = fileURLToPath(new URL('./test-pace.sh', import.meta.url));
const result = spawnSync('bash', [runnerPath,
  'PaceUtteranceEndpointDetectorTests',
  'GlobalPushToTalkShortcutMonitorTests',
  'PaceNativeInterfaceModelTests',
  'PaceDiagramTests',
], { cwd: repositoryRoot, stdio: 'inherit', env: process.env });
if (result.error) console.error(result.error.message);
if (result.signal) console.error(`Native checks terminated by ${result.signal}`);
process.exit(result.status ?? 1);
