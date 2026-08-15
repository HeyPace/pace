#!/usr/bin/env node

import { spawnSync } from 'node:child_process';

// Accepted review inventory: https://github.com/HeyPace/pace/issues/154.
const maximumFindingCount = 74;

const version = spawnSync('periphery', ['version'], { encoding: 'utf8' });
if (version.status !== 0) {
  if (version.stderr) process.stderr.write(version.stderr);
  console.error('Periphery is required. Install it with: brew install periphery');
  process.exit(1);
}

const result = spawnSync('periphery', ['scan', '--format', 'json', '--quiet'], {
  encoding: 'utf8',
  maxBuffer: 32 * 1024 * 1024,
});
if (result.status !== 0) {
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  process.exit(result.status ?? 1);
}

let findings;
try {
  findings = JSON.parse(result.stdout);
} catch {
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  console.error('Periphery did not return valid JSON.');
  process.exit(1);
}

const countsByKind = Object.groupBy(findings, (finding) => finding.kind);
const kindSummary = Object.entries(countsByKind)
  .sort(([left], [right]) => left.localeCompare(right))
  .map(([kind, entries]) => `${kind}=${entries.length}`)
  .join(', ');
console.log(`Periphery ${version.stdout.trim()}: ${findings.length} findings (${kindSummary}).`);

if (findings.length > maximumFindingCount) {
  console.error(`Unused-code findings exceed the accepted baseline of ${maximumFindingCount}.`);
  process.exit(1);
}
if (findings.length < maximumFindingCount) {
  console.log('Unused-code findings improved; lower the checked-in baseline in the next intentional update.');
}
