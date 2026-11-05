import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repositoryRoot = fileURLToPath(new URL('../', import.meta.url));
const runnerPath = fileURLToPath(new URL('./test-pace.sh', import.meta.url));
const result = spawnSync('bash', [runnerPath,
  'LocalTTSPlaybackStateTests',
  'StreamingSentenceTTSPipelineDispatchTests',
  'PaceBargeInVADIntegrationTests',
  'PaceUtteranceEndpointDetectorTests',
  'GlobalPushToTalkShortcutMonitorTests',
  'PaceNativeInterfaceModelTests',
  'PaceActiveDisplayCoordinatorTests',
  'PaceDiagramTests',
  'PaceActionApprovalTests',
  'PaceBoundedTextAnswerPlannerTests',
  'PaceLocalCLIStreamJSONParserTests',
  'CompanionSystemPromptPlanThenExecuteTests',
  'PaceAutoUpdateControllerTests',
], { cwd: repositoryRoot, stdio: 'inherit', env: process.env });
if (result.error) console.error(result.error.message);
if (result.signal) console.error(`Native checks terminated by ${result.signal}`);
process.exit(result.status ?? 1);
