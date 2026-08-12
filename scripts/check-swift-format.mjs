#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const excludedSegments = new Set(['.build', 'DerivedData', 'Generated', 'generated']);

function git(args, { allowFailure = false } = {}) {
  const result = spawnSync('git', args, { encoding: 'utf8' });
  if (!allowFailure && result.status !== 0) {
    process.stderr.write(result.stderr);
    process.exit(result.status ?? 1);
  }
  return result;
}

function isIncludedSwiftPath(filePath) {
  return filePath.endsWith('.swift')
    && !filePath.split('/').some((segment) => excludedSegments.has(segment));
}

function resolveComparisonBase() {
  const candidates = [process.env.CODE_HEALTH_BASE, 'origin/main', 'HEAD^'].filter(Boolean);
  for (const candidate of candidates) {
    if (candidate === '0000000000000000000000000000000000000000') continue;
    if (git(['rev-parse', '--verify', `${candidate}^{commit}`], { allowFailure: true }).status !== 0) continue;
    const mergeBase = git(['merge-base', 'HEAD', candidate], { allowFailure: true });
    return mergeBase.status === 0 ? mergeBase.stdout.trim() : candidate;
  }
  return null;
}

function changedRanges(base) {
  const ranges = new Map();
  if (!base) return ranges;

  const diff = git([
    'diff', '--unified=0', '--no-color', '--find-renames', '--diff-filter=ACMR',
    base, '--', '*.swift',
  ]).stdout;
  let currentPath = null;
  for (const line of diff.split('\n')) {
    if (line.startsWith('+++ b/')) {
      const candidate = line.slice(6);
      currentPath = isIncludedSwiftPath(candidate) ? candidate : null;
      continue;
    }
    if (!currentPath || !line.startsWith('@@')) continue;
    const match = line.match(/\+(\d+)(?:,(\d+))?/u);
    if (!match) continue;
    const start = Number(match[1]);
    const count = match[2] === undefined ? 1 : Number(match[2]);
    if (count === 0) continue;
    if (!ranges.has(currentPath)) ranges.set(currentPath, []);
    ranges.get(currentPath).push([start, start + count - 1]);
  }
  return ranges;
}

function addUntrackedFiles(ranges) {
  const output = git(['ls-files', '--others', '--exclude-standard', '--', '*.swift']).stdout;
  for (const filePath of output.split('\n').filter(isIncludedSwiftPath)) {
    const lineCount = readFileSync(filePath, 'utf8').split('\n').length;
    ranges.set(filePath, [[1, Math.max(1, lineCount)]]);
  }
}

function mergeRanges(ranges) {
  const merged = [];
  for (const range of [...ranges].sort((left, right) => left[0] - right[0])) {
    const previous = merged.at(-1);
    if (previous && range[0] <= previous[1] + 1) previous[1] = Math.max(previous[1], range[1]);
    else merged.push([...range]);
  }
  return merged;
}

const base = resolveComparisonBase();
const files = changedRanges(base);
addUntrackedFiles(files);

if (files.size === 0) {
  console.log(`Swift format: no changed Swift lines${base ? ` since ${base.slice(0, 12)}` : ''}.`);
  process.exit(0);
}

let failed = false;
for (const [filePath, rawRanges] of [...files].sort(([left], [right]) => left.localeCompare(right))) {
  const ranges = mergeRanges(rawRanges);
  const args = [
    'swift-format', 'lint', '--strict', '--configuration', '.swift-format',
    filePath,
  ];
  console.log(`Swift format: ${filePath} (${ranges.map(([start, end]) => `${start}:${end}`).join(', ')})`);
  const result = spawnSync('xcrun', args, { encoding: 'utf8' });
  const output = `${result.stdout}${result.stderr}`;
  const diagnostics = output.split('\n').filter((line) => line.includes(': error:'));
  const changedDiagnostics = diagnostics.filter((line) => {
    const match = line.match(/\.swift:(\d+):\d+: error:/u);
    if (!match) return false;
    const lineNumber = Number(match[1]);
    return ranges.some(([start, end]) => lineNumber >= start && lineNumber <= end);
  });
  if (result.status !== 0 && diagnostics.length === 0) {
    process.stdout.write(result.stdout);
    process.stderr.write(result.stderr);
    failed = true;
  } else if (changedDiagnostics.length > 0) {
    console.error(changedDiagnostics.join('\n'));
    failed = true;
  } else if (diagnostics.length > 0) {
    console.log(`Swift format: ignored ${diagnostics.length} pre-existing diagnostics outside changed lines.`);
  }
}

if (failed) process.exit(1);
console.log(`Swift format: ${files.size} changed file${files.size === 1 ? '' : 's'} passed.`);
