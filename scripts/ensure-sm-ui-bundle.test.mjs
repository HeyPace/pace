import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const scripts = path.dirname(fileURLToPath(import.meta.url));
const bundleName = 'SaaSMakerUI_SaaSMakerUI.bundle';

function fixture() {
  const directory = mkdtempSync(path.join(tmpdir(), 'pace-sm-bundle-test-'));

  const app = path.join(directory, 'Pace with spaces.app');
  mkdirSync(path.join(app, 'Contents', 'Resources'), { recursive: true });
  return { directory, app, bundle: path.join(app, 'Contents', 'Resources', bundleName) };
}

function check(app, products) {
  return spawnSync('bash', [path.join(scripts, 'ensure-sm-ui-bundle.sh'), app, ...(products ? [products] : [])], { encoding: 'utf8' });
}

test('missing package bundle fails instead of shipping a launch crash', () => {
  const { directory, app } = fixture();
  const result = check(app, directory);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /missing SaaSMakerUI font bundle.*crash at launch/);
});

test('already embedded bundle passes without build products', () => {
  const { app, bundle } = fixture();
  mkdirSync(bundle);
  assert.equal(check(app).status, 0);
});

test('copies missing resources from build products, including paths with spaces', () => {
  const { directory, app, bundle } = fixture();
  const source = path.join(directory, bundleName);
  mkdirSync(source);
  writeFileSync(path.join(source, 'fixture-font'), 'synthetic font fixture');
  const result = check(app, directory);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(path.join(bundle, 'fixture-font'), 'utf8'), 'synthetic font fixture');
});

test('release entry points keep the bundle gate before signing or copying', () => {
  for (const [filename, boundary] of [['prepare-release.sh', 'ditto "$BUILT_APP"'], ['release-pace.sh', 'codesign --force']]) {
    const script = readFileSync(path.join(scripts, filename), 'utf8');
    const gate = script.indexOf('bash "$SCRIPT_DIR/ensure-sm-ui-bundle.sh"');
    const releaseGate = script.indexOf('bash "$PROJECT_DIR/scripts/ensure-sm-ui-bundle.sh"');
    const offset = Math.max(gate, releaseGate);
    assert.ok(offset >= 0, `${filename} must verify package resources`);
    assert.ok(script.indexOf(boundary) > offset, `${filename} must gate signing/copy on resources`);
  }
  const readiness = readFileSync(path.join(scripts, 'release-readiness.sh'), 'utf8');
  assert.match(readiness, /if bash "\$SCRIPT_DIR\/ensure-sm-ui-bundle.sh"[\s\S]*?then\s+echo "pass"\s+else\s+echo "fail"/);
});
