#!/usr/bin/env node

import { spawnSync } from 'node:child_process';

// Accepted legacy findings are tracked in https://github.com/HeyPace/pace/issues/154.
// The gate permits only these exact high-severity advisory IDs and never a critical finding.
const scopes = [
  {
    name: 'docs',
    directory: '.',
    acceptedHigh: new Set(['1138808', '1138809']),
  },
  {
    name: 'website',
    directory: 'website',
    acceptedHigh: new Set(['1120912', '1120917', '1124066']),
  },
];

let failed = false;
for (const scope of scopes) {
  const result = spawnSync('pnpm', ['audit', '--json'], {
    cwd: scope.directory,
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
  });
  let report;
  try {
    report = JSON.parse(result.stdout);
  } catch {
    process.stderr.write(result.stderr);
    console.error(`${scope.name}: pnpm audit did not return valid JSON.`);
    failed = true;
    continue;
  }

  const advisories = Object.entries(report.advisories ?? {});
  const critical = advisories.filter(([, advisory]) => advisory.severity === 'critical');
  const high = advisories.filter(([, advisory]) => advisory.severity === 'high');
  const unexpectedHigh = high.filter(([id]) => !scope.acceptedHigh.has(id));
  const resolvedHigh = [...scope.acceptedHigh].filter((id) => !high.some(([current]) => current === id));

  console.log(
    `${scope.name}: ${critical.length} critical, ${high.length} high, `
      + `${report.metadata?.vulnerabilities?.moderate ?? 0} moderate, `
      + `${report.metadata?.vulnerabilities?.low ?? 0} low.`,
  );
  if (resolvedHigh.length > 0) {
    console.error(`${scope.name}: remove resolved high advisory IDs from the accepted baseline: ${resolvedHigh.join(', ')}`);
    failed = true;
  }
  for (const [id, advisory] of [...critical, ...unexpectedHigh]) {
    console.error(`${scope.name}: unaccepted ${advisory.severity} advisory ${id} in ${advisory.module_name}: ${advisory.title}`);
    failed = true;
  }
}

if (failed) process.exit(1);
console.log('Dependency risk: no critical or unaccepted high advisories.');
