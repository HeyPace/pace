#!/usr/bin/env node

import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

// Accepted legacy baseline: https://github.com/HeyPace/pace/issues/154.
const baseline = {
  duplicatedLines: 1442,
  percentage: 1.7330689261462653,
};

const outputDirectory = mkdtempSync(join(tmpdir(), 'pace-jscpd-'));
const result = spawnSync('pnpm', [
  'exec', 'jscpd', 'leanring-buddy',
  '--min-lines', '8',
  '--min-tokens', '60',
  '--mode', 'strict',
  '--format', 'swift',
  '--ignore', '**/Generated/**,**/generated/**,**/.build/**,**/DerivedData/**',
  '--reporters', 'json',
  '--output', outputDirectory,
  '--silent',
  '--no-tips',
], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });

if (result.status !== 0) {
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  process.exit(result.status ?? 1);
}

const report = JSON.parse(readFileSync(join(outputDirectory, 'jscpd-report.json'), 'utf8'));
const observed = report.statistics.total;
console.log(
  `Swift duplication: ${observed.duplicatedLines}/${observed.lines} lines `
    + `(${observed.percentage.toFixed(4)}%), ${observed.clones} clone groups.`,
);

if (
  observed.duplicatedLines > baseline.duplicatedLines
  || observed.percentage > baseline.percentage
) {
  console.error(
    `Duplication exceeds the accepted baseline of ${baseline.duplicatedLines} lines `
      + `(${baseline.percentage.toFixed(4)}%).`,
  );
  process.exit(1);
}

if (
  observed.duplicatedLines < baseline.duplicatedLines
  || observed.percentage < baseline.percentage
) {
  console.log('Duplication improved; lower the checked-in baseline in the next intentional update.');
}
