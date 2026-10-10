import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const requiredTestIdentifiers = [
  'PaceDesktopRequestsTests/plannerCanComposeWorkAppsAndFolderSpecificCodexSession()',
  'PaceDesktopRequestsTests/recordingModesRemainDistinctAndInvalidModesFailClosed()',
  'PaceDesktopRequestsTests/workProfileUsesSavedDirectoryAndExplicitBrowserIsHonored()',
  'PaceDesktopRequestsTests/warpConfigurationCannotTurnFolderOrExecutableIntoInjectedCommands()',
  'PaceDesktopRequestsTests/folderlessCodexRequestsClarifyInsteadOfReusingOldDirectories()',
  'PaceDesktopPointingTests/desktopPointPreservesSignedFractionalCoordinatesAndStripsTag()',
  'PaceDesktopPointingTests/screenshotPointRetainsItsCoordinateSpace()',
  'PaceDesktopPointingTests/desktopTargetUsesSecondaryDisplayWithoutScreenshotScaling()',
  'PaceDesktopPointingTests/desktopTargetSupportsDisplaysAboveAndLeftOfPrimary()',
  'PaceDesktopPointingTests/desktopTargetRejectsCoordinatesOutsideConnectedDisplays()',
  'PaceActionApprovalTests/screenExplanationCannotBecomeDictation()',
  'PaceActionApprovalTests/observationOnlyAllowsInspectionButRejectsMixedMutationPlans()',
  'PaceActionApprovalTests/pointingWithoutClickingRequiresObservationOnly()',
  'PaceScreenRecordingControllerTests/deniedPermissionDoesNotLaunchOrCreateRecordingStorage()',
  'PaceScreenRecordingControllerTests/stoppingWithoutAnOwnedRecordingDoesNotTouchOtherRecordings()',
  'PaceScreenRecordingControllerTests/recordingLifecycleCanBeComposedByThePlanner()',
  'PaceDesktopRequestsTests/captureToolbarPreservesNativeDestinationSettings()',
  'PaceDesktopRequestsTests/foregroundCodexDoesNotInheritToolsOrRequireGitRepository()',
  'PaceDesktopRequestsTests/codexComputerUsePromptRequestsFreshObservationsBeforeDependentActions()',
  'PaceDesktopPointingTests/optOutRemainsSafe()',
  'PaceScreenRecordingControllerTests/unwritableDestinationFailsBeforeStartingCapture()',
  'PaceActionApprovalTests/approvalRequestRequiresEnabledPreferenceAndNonEmptySummary()',
  'PaceActionApprovalTests/approvalRequestBuildsPopupCopyWithRiskSummary()',
  'PaceActionApprovalTests/cancellationBlocksExecution()',
  'PaceActionApprovalTests/allowOncePermitsExecution()',
  'PaceActionApprovalTests/missingApprovalRequestPassesThrough()',
  'PaceActionApprovalTests/routineLocalActionsDoNotRequireExplicitApproval()',
  'PaceActionApprovalTests/routineLocalActionsSuppressInitialSpokenFeedback()',
  'PaceActionApprovalTests/emptyOrRiskyPlansDoNotSuppressInitialSpokenFeedback()',
  'PaceActionApprovalTests/routinePlannerResponseTextSuppressesInitialSpokenFeedback()',
  'PaceActionApprovalTests/answerAndRiskyPlannerResponseTextDoNotSuppressInitialSpokenFeedback()',
  'PaceActionApprovalTests/nonUndoableAndExternalActionsRequireExplicitApproval()',
  'PaceActionApprovalTests/messagesWithDraftTextRequireExplicitApproval()',
  'PaceActionApprovalTests/blockingPreflightIssueRequiresExplicitApproval()',
];

export function verifyCommandResults(summary, testTree, startedAt) {
  assert.equal(summary.result, 'Passed', 'The result bundle must pass');
  assert.equal(summary.failedTests, 0, 'Failed tests cannot pass verification');
  assert.equal(summary.skippedTests, 0, 'Skipped tests cannot pass verification');
  assert.ok(Number.isFinite(startedAt), 'A run start marker is required');
  assert.ok(Number.isFinite(summary.startTime) && summary.startTime >= startedAt,
    'The result bundle must belong to this run');
  assert.ok(Number.isFinite(summary.finishTime) && summary.finishTime >= summary.startTime,
    'The result bundle must have a valid completion time');

  const testCases = [];
  function visit(nodes) {
    assert.ok(Array.isArray(nodes), 'The test tree must contain nodes');
    for (const node of nodes) {
      if (node.nodeType === 'Test Case') testCases.push(node);
      if (node.children) visit(node.children);
    }
  }
  visit(testTree.testNodes);
  assert.equal(summary.totalTestCount, testCases.length, 'Summary and test tree must agree');
  assert.equal(summary.passedTests, testCases.length, 'Every executed test must pass');
  const testIdentifiers = new Set();
  const allowedSuites = new Set(requiredTestIdentifiers.map(identifier => identifier.split('/')[0]));
  for (const testCase of testCases) {
    assert.equal(testCase.result, 'Passed', 'Every required case must pass');
    assert.ok(allowedSuites.has(testCase.nodeIdentifier?.split('/')[0]), 'Unexpected test suite');
    assert.ok(!testIdentifiers.has(testCase.nodeIdentifier), 'Duplicate test identifier');
    testIdentifiers.add(testCase.nodeIdentifier);
  }
  for (const identifier of requiredTestIdentifiers) {
    assert.ok(testIdentifiers.has(identifier), `Missing required command check: ${identifier}`);
  }
  return { passedTests: testCases.length, scope: 'unit command contracts; no native UI acceptance' };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    assert.ok(process.env.FLEET_AGENT_TEST_RUN_DIR, 'Run this adapter through agent-testing');
    const startMarkerPath = resolve(process.env.FLEET_AGENT_TEST_RUN_DIR, 'command-test-start.json');
    if (process.argv[2] === 'reset') {
      writeFileSync(startMarkerPath, JSON.stringify({ startedAt: Date.now() / 1000 }));
    } else {
      assert.equal(process.argv[2], 'verify', 'Expected reset or verify');
      const { startedAt } = JSON.parse(readFileSync(startMarkerPath, 'utf8'));
      const resultBundlePath = '/tmp/pace-test-derived-data/pace-tests.xcresult';
      const readResults = kind => JSON.parse(execFileSync('xcrun', [
        'xcresulttool', 'get', 'test-results', kind, '--path', resultBundlePath, '--compact',
      ], { encoding: 'utf8', timeout: 10000, maxBuffer: 4 * 1024 * 1024 }));
      console.log(JSON.stringify(verifyCommandResults(readResults('summary'), readResults('tests'), startedAt)));
    }
  } catch (error) {
    console.error(`Pace command verification: ${error.message}`);
    process.exitCode = 1;
  }
}
