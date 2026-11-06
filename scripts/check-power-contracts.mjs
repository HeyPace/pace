import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repositoryRoot = fileURLToPath(new URL('../', import.meta.url));
const runnerPath = fileURLToPath(new URL('./test-pace.sh', import.meta.url));
const result = spawnSync('bash', [runnerPath,
  'PersistedVoiceSettingsTests',
  'LocalServerTTSConfigurationTests',
  'LocalTTSPlaybackStateTests',
  'LocalServerTTSClientIntegrationTests',
  'PacePowerCatalogTests',
  'PaceToolRegistryTests',
  'PaceDiagramTests',
  'PaceImageGenerationTests',
  'PaceAnnotationParserTests',
  'PaceAnnotationOverlayControllerTests',
  'PaceAnnotationCoordinateMapperTests',
  'CompanionSystemPromptResearchTurnTests',
  'CompanionSystemPromptPlanThenExecuteTests',
  'PaceDesktopRequestsTests',
  'PaceFigureSceneTests',
  'PaceFigureCameraFramingTests',
], { cwd: repositoryRoot, stdio: 'inherit', env: process.env });
if (result.error) console.error(result.error.message);
if (result.signal) console.error(`Native power checks terminated by ${result.signal}`);
process.exit(result.status ?? 1);
