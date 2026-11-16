import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

test('Saved powers preserve CRUD, execution authorization, media and speech lifecycle contracts', () => {
  const repositoryRoot = fileURLToPath(new URL('../', import.meta.url));
  const result = spawnSync('bash', [
    'scripts/test-pace.sh',
    'PaceManagedPowerTests',
    'PacePowerManagerTests',
    'PacePowerCatalogTests',
    'PaceAutomationDefinitionTests',
    'PaceProgramModelTests',
    'PaceUserProgramStoreTests',
    'PaceSkillLoaderTests',
    'PaceAutomationCatalogTests',
    'PaceToolRegistryTests',
    'PaceActionApprovalTests',
    'PaceActionResultAndPreflightTests',
  ], { cwd: repositoryRoot, stdio: 'inherit', env: process.env });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `Native power checks failed (${result.signal ?? result.status})`);
});
