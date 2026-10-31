import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repositoryRoot = fileURLToPath(new URL('../', import.meta.url));
const result = spawnSync('bash', [
  'scripts/test-pace.sh',
  'PaceScreenSuggestionCoordinatorTests',
  'PaceScreenSuggestionBoundaryTests',
  'PaceScreenSuggestionIntegrationTests',
  'PaceScreenImageDifferTests',
  'PaceChatSessionTests',
  'PaceExistingPerceptionAdaptersTests',
  'PaceProactiveNudgeFrameworkTests',
  'PaceRestraintGateTests',
], { cwd: repositoryRoot, stdio: 'inherit' });
if (result.error) throw result.error;
process.exit(result.status ?? 1);
