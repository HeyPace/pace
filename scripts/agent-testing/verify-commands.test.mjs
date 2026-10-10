import assert from 'node:assert/strict';
import test from 'node:test';
import { requiredTestIdentifiers, verifyCommandResults } from './verify-commands.mjs';

function results() {
  const testNodes = requiredTestIdentifiers.map(nodeIdentifier => ({
    nodeType: 'Test Case', nodeIdentifier, result: 'Passed',
  }));
  return {
    summary: {
      result: 'Passed', failedTests: 0, skippedTests: 0,
      totalTestCount: testNodes.length, passedTests: testNodes.length,
      startTime: 101, finishTime: 102,
    },
    tree: { testNodes },
  };
}

test('accepts fresh passing command checks with an explicit unit-only scope', () => {
  const { summary, tree } = results();
  assert.equal(verifyCommandResults(summary, tree, 100).passedTests, requiredTestIdentifiers.length);
  assert.match(verifyCommandResults(summary, tree, 100).scope, /no native UI acceptance/);
});

for (const [name, damage] of [
  ['stale result', fixture => { fixture.summary.startTime = 99; }],
  ['empty execution', fixture => {
    fixture.tree.testNodes = []; fixture.summary.totalTestCount = 0; fixture.summary.passedTests = 0;
  }],
  ['missing pointer check', fixture => {
    fixture.tree.testNodes.splice(5, 1); fixture.summary.totalTestCount--; fixture.summary.passedTests--;
  }],
  ['skipped check', fixture => { fixture.summary.skippedTests = 1; }],
  ['failed case with a green summary', fixture => { fixture.tree.testNodes[0].result = 'Failed'; }],
  ['summary mismatch', fixture => { fixture.summary.totalTestCount++; }],
  ['duplicate case', fixture => {
    fixture.tree.testNodes[1].nodeIdentifier = fixture.tree.testNodes[0].nodeIdentifier;
  }],
  ['unrelated suite', fixture => { fixture.tree.testNodes[0].nodeIdentifier = 'UnrelatedTests/passed()'; }],
]) {
  test(`rejects ${name} despite a successful driver exit`, () => {
    const fixture = results(); damage(fixture);
    assert.throws(() => verifyCommandResults(fixture.summary, fixture.tree, 100));
  });
}
