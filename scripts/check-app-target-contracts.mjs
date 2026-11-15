import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

test('App targeting preserves observation, action and conversation boundaries', () => {
  const repositoryRoot = fileURLToPath(new URL('../', import.meta.url));
  const result = spawnSync('bash', [
    'scripts/test-pace.sh',
    'PaceMCPClientIntegrationTests',
    'PaceInitialInspectionPlanResolverTests',
    'PacePlannerCredentialStoreTests',
    'PaceBoundedTextAnswerPlannerTests',
    'PaceActionApprovalTests',
    'PaceChatTranscriptModelTests',
    'PaceActionResultAndPreflightTests',
    'PaceActionExecutorDryRunTests',
    'PaceTurnHUDStateTests',
    'PaceEverydayAnswerClientTests',
  ], { cwd: repositoryRoot, stdio: 'inherit', env: process.env });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `Native app-target checks failed (${result.signal ?? result.status})`);
});
