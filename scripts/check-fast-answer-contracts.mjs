import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

test('Fast answers preserve credential, consent and fallback boundaries', () => {
  const repositoryRoot = fileURLToPath(new URL('../', import.meta.url));
  const result = spawnSync('bash', [
    'scripts/test-pace.sh',
    'PacePlannerCredentialStoreTests',
    'PaceEverydayAnswerClientTests',
    'PaceBoundedTextAnswerPlannerTests',
    'PaceCLIDirectPlannerTierTests',
  ], { cwd: repositoryRoot, stdio: 'inherit', env: process.env });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `Native fast-answer checks failed (${result.signal ?? result.status})`);
});
