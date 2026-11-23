//
//  PaceActionExecutorDryRunTests.swift
//  leanring-buddyTests
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceActionExecutorDryRunTests {
    @Test func targetedScrollUsesTheSelectedDisplayAndRejectsItsEdges() throws {
        let screenHeight = try #require(NSScreen.screens.first).frame.height
        let primary = CompanionScreenCapture(
            imageData: Data(), label: "Screen 1", isCursorScreen: true,
            displayWidthInPoints: 800, displayHeightInPoints: 600,
            displayFrame: CGRect(x: 0, y: screenHeight - 600, width: 800, height: 600),
            screenshotWidthInPixels: 1600, screenshotHeightInPixels: 1200)
        let secondary = CompanionScreenCapture(
            imageData: Data(), label: "Screen 2", isCursorScreen: false,
            displayWidthInPoints: 800, displayHeightInPoints: 600,
            displayFrame: CGRect(x: -800, y: screenHeight - 600, width: 800, height: 600),
            screenshotWidthInPixels: 1600, screenshotHeightInPixels: 1200)
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let captures = [primary, secondary]
        let location = ScreenshotPixelLocation(xInScreenshotPixels: 640, yInScreenshotPixels: 280, screenNumber: 2)
        let edge = ScreenshotPixelLocation(xInScreenshotPixels: 1600, yInScreenshotPixels: 280, screenNumber: 2)
        let globalPoint = executor.convertScreenshotPixelToDisplayGlobalPoint(
            screenshotPixelLocation: location, screenCaptures: captures, requiresExactLocation: true)
        let edgePoint = executor.convertScreenshotPixelToDisplayGlobalPoint(
            screenshotPixelLocation: edge, screenCaptures: captures, requiresExactLocation: true)
        #expect(globalPoint == CGPoint(x: -480, y: 140))
        #expect(edgePoint == nil)
    }

    @Test func targetedScrollNeverFallsBackToTheCurrentPointerWhenCaptureIsUnavailable() async throws {
        let location = ScreenshotPixelLocation(xInScreenshotPixels: 320, yInScreenshotPixels: 120, screenNumber: 2)
        let action = PaceParsedAction.scroll(.up, amountInLines: 5, location: location)
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: true, accessibilityPermissionCheck: { true }, readMyScreenIsEnabled: { true })
        let results = await executor.executeActionPlan(.serial(actions: [action]), screenCaptures: [])
        let result = try #require(results.first)
        #expect(result.toolName == "scroll")
        #expect(result.summary.contains("Could not locate"))
        #expect(result.stopsActionPlan)
        #expect(result.requiresFreshInspectionPlan)
        let retry = await executor.executeActionPlan(.serial(actions: [action]), screenCaptures: [])
        #expect(retry.first?.stopsAgentLoop == true)

        let privateExecutor = PaceActionExecutor(
            actionsAreEnabledOverride: true, accessibilityPermissionCheck: { true }, readMyScreenIsEnabled: { false })
        let blocked = await privateExecutor.executeActionPlan(.serial(actions: [action]), screenCaptures: [])
        #expect(blocked.first?.summary.contains("Read My Screen is off") == true)
        #expect(blocked.first?.stopsActionPlan == true)
    }

    @Test func launchedProcessBindsOnlyKnownNameSelectorsAndPreservesExactReceipts() throws {
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: false, runningApplicationBundleURL: { _ in chromeURL })
        executor.rememberLaunchedApplication(
            named: "Chrome", processIdentifier: 4123, bundleURL: chromeURL,
            generation: executor.applicationTargetGeneration)
        for (toolName, fieldName) in [("window", "app"), ("see", "app_target")] {
            let request = PaceMCPToolCall(
                serverName: "peekaboo", toolName: toolName, arguments: [fieldName: .string("Google Chrome")])
            #expect(try executor.boundPeekabooToolCall(request).arguments[fieldName] == .string("PID:4123"))
            for exactSelector in ["pid", "window_id", "snapshot", "coordinate_reference"] {
                var exactArguments = request.arguments
                exactArguments[exactSelector] = .string("explicit-receipt")
                let exactRequest = PaceMCPToolCall(
                    serverName: "peekaboo", toolName: toolName, arguments: exactArguments)
                #expect(try executor.boundPeekabooToolCall(exactRequest) == exactRequest)
            }
            for relativeSelector in ["window_index", "window_title", "window_target"] {
                var arguments = request.arguments
                arguments[relativeSelector] = .string("preserved-window-selector")
                let targetedRequest = PaceMCPToolCall(serverName: "peekaboo", toolName: toolName, arguments: arguments)
                let boundRequest = try executor.boundPeekabooToolCall(targetedRequest)
                #expect(boundRequest.arguments[fieldName] == .string("PID:4123"))
                #expect(boundRequest.arguments[relativeSelector] == .string("preserved-window-selector"))
            }
        }
        for request in [
            PaceMCPToolCall(serverName: "peekaboo", toolName: "window", arguments: ["app": .string("PID:9999")]),
            PaceMCPToolCall(serverName: "peekaboo", toolName: "window", arguments: ["app": .string("Safari")]),
            PaceMCPToolCall(serverName: "peekaboo", toolName: "see", arguments: ["app": .string("Chrome")]),
            PaceMCPToolCall(
                serverName: "peekaboo", toolName: "click",
                arguments: ["app": .string("Chrome"), "foreground": .bool(false)]),
            PaceMCPToolCall(serverName: "other", toolName: "window", arguments: ["app": .string("Chrome")]),
        ] {
            #expect(try executor.boundPeekabooToolCall(request) == request)
        }
    }

    @Test func launchedProcessCannotBeReplacedByAReusedPIDOrGuessedAfterProfileLaunch() throws {
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: false,
            runningApplicationBundleURL: { _ in
                URL(fileURLWithPath: "/Applications/Other.app")
            })
        executor.rememberLaunchedApplication(
            named: "Chrome", processIdentifier: 4123, bundleURL: chromeURL,
            generation: executor.applicationTargetGeneration)
        let request = PaceMCPToolCall(
            serverName: "peekaboo", toolName: "window", arguments: ["app": .string("Google Chrome")])
        #expect(throws: PaceMCPClientError.self) { try executor.boundPeekabooToolCall(request) }
        executor.forgetLaunchedApplication(named: "Chrome")
        #expect(try executor.boundPeekabooToolCall(request) == request)
    }

    @Test func turnResetRejectsOldLaunchCompletionsWithoutClearingNewTargets() throws {
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let notesURL = URL(fileURLWithPath: "/System/Applications/Notes.app")
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: false,
            runningApplicationBundleURL: { processIdentifier in
                processIdentifier == 5000 ? chromeURL : notesURL
            })
        let oldGeneration = executor.applicationTargetGeneration
        executor.rememberLaunchedApplication(
            named: "Chrome", processIdentifier: 4000, bundleURL: chromeURL, generation: oldGeneration)
        executor.beginUserTurn()
        let chromeRequest = PaceMCPToolCall(
            serverName: "peekaboo", toolName: "window", arguments: ["app": .string("Chrome")])
        #expect(try executor.boundPeekabooToolCall(chromeRequest) == chromeRequest)
        executor.rememberLaunchedApplication(
            named: "Chrome", processIdentifier: 5000, bundleURL: chromeURL,
            generation: executor.applicationTargetGeneration)
        executor.rememberLaunchedApplication(
            named: "Notes", processIdentifier: 6000, bundleURL: notesURL,
            generation: executor.applicationTargetGeneration)
        executor.rememberLaunchedApplication(
            named: "Chrome", processIdentifier: 4000, bundleURL: chromeURL, generation: oldGeneration)
        #expect(try executor.boundPeekabooToolCall(chromeRequest).arguments["app"] == .string("PID:5000"))
        let notesRequest = PaceMCPToolCall(
            serverName: "peekaboo", toolName: "see", arguments: ["app_target": .string("Notes")])
        #expect(try executor.boundPeekabooToolCall(notesRequest).arguments["app_target"] == .string("PID:6000"))
    }

    @Test func browserProfileLaunchForgetsCanonicalChromeBindingAcrossAliases() async throws {
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: false, runningApplicationBundleURL: { _ in chromeURL })
        executor.rememberLaunchedApplication(
            named: "Google Chrome", processIdentifier: 4123, bundleURL: chromeURL,
            generation: executor.applicationTargetGeneration)
        let request = PaceMCPToolCall(serverName: "peekaboo", toolName: "window", arguments: ["app": .string("Chrome")])
        #expect(try executor.boundPeekabooToolCall(request).arguments["app"] == .string("PID:4123"))
        _ = await executor.openBrowser(.init(browserName: "Chrome", url: nil, chromeProfile: "work"))
        #expect(try executor.boundPeekabooToolCall(request) == request)
        let canonicalRequest = PaceMCPToolCall(
            serverName: "peekaboo", toolName: "see", arguments: ["app_target": .string("Google Chrome")])
        #expect(try executor.boundPeekabooToolCall(canonicalRequest) == canonicalRequest)
    }

    @Test func cancelledLaunchCompletionDoesNotInstallTargetInCurrentTurn() async throws {
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: false, runningApplicationBundleURL: { _ in chromeURL })
        let generation = executor.applicationTargetGeneration
        let completion = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            executor.rememberLaunchedApplication(
                named: "Chrome", processIdentifier: 4123, bundleURL: chromeURL, generation: generation)
        }
        completion.cancel()
        await completion.value
        let request = PaceMCPToolCall(serverName: "peekaboo", toolName: "window", arguments: ["app": .string("Chrome")])
        #expect(try executor.boundPeekabooToolCall(request) == request)
    }

    @Test func terminalObservationStopsTheRestOfThePlanButUncertainDispatchCanContinue() async {
        let terminalReasons: [PaceActionExecutionObservation.TerminalReason?] = [.ambiguousApplicationTarget, nil]
        for terminalReason in terminalReasons {
            let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
            var dispatchCount = 0
            executor.executeCodingSession = { _ in
                dispatchCount += 1
                return .init(
                    toolName: "test", summary: "Dispatch unverified; obtain fresh observation.",
                    terminalReason: terminalReason)
            }
            let statusAction = PaceParsedAction.codingSession(.status(sessionID: nil))
            let observations = await executor.executeActionPlan(
                .init(steps: [.init(actions: [statusAction, statusAction]), .init(actions: [statusAction])]),
                screenCaptures: [])
            #expect(dispatchCount == (terminalReason == nil ? 3 : 1))
            #expect(observations.contains(where: \.stopsAgentLoop) == (terminalReason != nil))
        }
    }

    @Test func missingAccessibilityBlocksInputAndReturnsActionableObservations() async {
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: true,
            accessibilityPermissionCheck: { false }
        )
        let observations = await executor.executeActionPlan(
            .serial(actions: [.type("must not be typed"), .pressKey(name: "return", modifiers: [])]),
            screenCaptures: []
        )

        #expect(observations.count == 2)
        #expect(observations.allSatisfy { $0.summary.contains("Could not control") })
        #expect(observations.allSatisfy { $0.summary.contains("Accessibility") })
        #expect(observations.allSatisfy { $0.summary.contains("No input was sent") })
        #expect(!PaceActionExecutor.requiresAccessibility(.openApplication("Chrome")))
        #expect(!PaceActionExecutor.requiresAccessibility(.codexSession(.init(directory: "/tmp"))))
    }

    @Test func dryRunKeyPressReportsThatNoInputWasSent() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let observations = await executor.executeActionPlan(
            .serial(actions: [.pressKey(name: "n", modifiers: [.command])]),
            screenCaptures: []
        )
        #expect(observations.count == 1)
        #expect(observations.first?.toolName == "key_press")
        #expect(observations.first?.summary == "Would press key: n")
    }

    @Test func cancelledPlanDoesNotDispatchActions() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .openApplication("Notes"),
            .openURL("example.com"),
        ])
        let executionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return await executor.executeActionPlan(actionPlan, screenCaptures: [])
        }

        executionTask.cancel()
        let observations = await executionTask.value

        #expect(observations.isEmpty)
    }

    @Test func dryRunAppleAndSystemToolsReturnNonMutatingObservations() async throws {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        #expect(executor.actionsAreEnabled == false)

        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .openApplication("Notes"),
            .openURL("example.com"),
            .controlMusic(.playPause),
            .readClipboard,
            .setTextValue(PaceSetTextValueRequest(value: "Dry run text", target: .focused)),
            .undoLastMutation,
            .snapWindow(PaceWindowSnapRequest(position: .left)),
            .listCalendarEvents(PaceCalendarQuery(range: .today)),
            .createCalendarEvent(PaceCalendarEventRequest(
                title: "Dry run calendar event",
                startDate: Date(timeIntervalSince1970: 1_780_000_000),
                endDate: Date(timeIntervalSince1970: 1_780_003_600),
                isAllDay: false,
                notes: nil,
                location: nil,
                calendarTitle: nil
            )),
            .createReminder(PaceReminderRequest(title: "Dry run reminder", notes: nil)),
            .finder(PaceFinderRequest(path: "~/Downloads", action: .reveal)),
            .createNote(PaceNoteRequest(title: "Dry run note", body: "No note should be created.")),
            .appendNote(PaceNoteRequest(title: "Dry run note", body: "Append nothing.")),
            .searchNotes("Dry run"),
            .composeMail(PaceMailDraft(
                recipients: ["alex@example.com"],
                subject: "Dry run",
                body: "No draft should be opened."
            )),
            .createThingsToDo(PaceThingsToDoRequest(title: "Dry run task", notes: nil)),
            .runShortcut("Dry Run Shortcut"),
            .openMessages(PaceMessageRequest(recipient: "Alex", text: "Dry run message")),
            .mcp(PaceMCPToolCall(
                serverName: "altic",
                toolName: "notes_create",
                arguments: ["title": .string("Dry run MCP note")]
            )),
        ])

        let observations = await executor.executeActionPlan(
            actionPlan,
            screenCaptures: []
        )
        let formattedObservations = PaceActionExecutionObservation.formatForPlanner(observations)

        #expect(formattedObservations.contains("Would open app: Notes"))
        #expect(formattedObservations.contains("Would open URL: https://example.com"))
        #expect(formattedObservations.contains("Would run Music command: playPause"))
        #expect(formattedObservations.contains("Would read clipboard text."))
        #expect(formattedObservations.contains("Would set focused text to"))
        #expect(formattedObservations.contains("Would undo the last editable text change."))
        #expect(formattedObservations.contains("Would snap focused window: left half"))
        #expect(formattedObservations.contains("Would list calendar events for today."))
        #expect(formattedObservations.contains("Would create calendar event: Dry run calendar event"))
        #expect(formattedObservations.contains("Would create reminder: Dry run reminder"))
        #expect(formattedObservations.contains("Would reveal path:"))
        #expect(formattedObservations.contains("Would create note: Dry run note"))
        #expect(formattedObservations.contains("Would append to note: Dry run note"))
        #expect(formattedObservations.contains("Would search notes for: Dry run"))
        #expect(formattedObservations.contains("Would compose mail draft"))
        #expect(formattedObservations.contains("Would create Things to-do: Dry run task"))
        #expect(formattedObservations.contains("Would run shortcut: Dry Run Shortcut"))
        #expect(formattedObservations.contains("Would open Messages"))
        #expect(formattedObservations.contains("Would call MCP tool: altic.notes_create"))
    }

    @Test func userFeedbackSummarizesToolResults() async throws {
        let feedback = PaceActionExecutionObservation.formatForUserFeedback([
            PaceActionExecutionObservation(toolName: "notes", summary: "Created note: Idea"),
        ])

        #expect(feedback == "Created note: Idea")

        let multiActionFeedback = PaceActionExecutionObservation.formatForUserFeedback([
            PaceActionExecutionObservation(toolName: "open_app", summary: "Opened app: Notes"),
            PaceActionExecutionObservation(toolName: "notes", summary: "Created note: Idea"),
        ])

        #expect(multiActionFeedback == "Opened app: Notes\nCreated note: Idea")
    }

    @Test func multiActionFeedbackDoesNotHideLaterFailures() {
        let feedback = PaceActionExecutionObservation.formatForUserFeedback([
            .init(toolName: "open_app", summary: "Opened app: Linear"),
            .init(toolName: "open_app", summary: "Could not find app: Missing App"),
            .init(toolName: "open_url", summary: "Opened https://example.com in Chrome"),
        ])
        #expect(feedback == "Opened app: Linear\nCould not find app: Missing App\nOpened https://example.com in Chrome")
    }

    @Test func snapshotMetadataIsExcludedFromConversationFeedback() {
        let observation = PaceActionExecutionObservation(
            toolName: "mcp.peekaboo.see",
            summary: "UI state captured\nTool structuredContent:\n" + String(repeating: "snapshot", count: 100_000)
        )
        #expect(PaceActionExecutionObservation.formatForUserFeedback([observation]) == "UI state captured")
        #expect(PaceActionExecutionObservation.formatForPlanner([observation]).contains("Tool structuredContent:"))
        let verboseObservation = PaceActionExecutionObservation(
            toolName: "mcp", summary: String(repeating: "x", count: 10_000)
        )
        #expect(PaceActionExecutionObservation.formatForUserFeedback([verboseObservation])?.count == 600)
    }

    @Test func mailtoDraftURLCarriesRecipientsAndSubjectWithoutBody() async throws {
        let mailtoURL = PaceActionExecutor.mailtoDraftURL(
            subject: "Project status & launch",
            resolvedRecipients: ["alex@example.com", "priya@example.com"]
        )

        #expect(mailtoURL?.absoluteString == "mailto:alex@example.com,priya@example.com?subject=Project%20status%20%26%20launch")
    }

    @Test func mailComposeBodyCandidatePrefersLargeBodyAreaOverHeaderFields() async throws {
        let bodyCandidate = PaceMailComposeBodyCandidateMetadata(
            role: "AXTextArea",
            title: nil,
            description: "Message Body",
            help: nil,
            value: nil,
            placeholder: nil,
            frame: CGRect(x: 0, y: 120, width: 680, height: 420)
        )
        let subjectCandidate = PaceMailComposeBodyCandidateMetadata(
            role: "AXTextField",
            title: "Subject:",
            description: nil,
            help: nil,
            value: "Project status",
            placeholder: "Subject",
            frame: CGRect(x: 0, y: 60, width: 680, height: 28)
        )

        #expect(bodyCandidate.score > subjectCandidate.score)
        #expect(subjectCandidate.score < 0)
    }

    @Test func fastKeyCommandsHaveVirtualKeyCodes() async throws {
        #expect(PaceActionExecutor.virtualKeyCode(forKeyName: "a") == 0x00)
        #expect(PaceActionExecutor.virtualKeyCode(forKeyName: "s") == 0x01)
        #expect(PaceActionExecutor.virtualKeyCode(forKeyName: "t") == 0x11)
        #expect(PaceActionExecutor.virtualKeyCode(forKeyName: "w") == 0x0D)
    }

    @Test func shortcutListParsingMatchesInstalledShortcutNamesCaseInsensitively() async throws {
        let installedShortcutNames = PaceActionExecutor.installedShortcutNames(fromListOutput: """

        Morning Brief
          Ship Pace
        Open Raycast

        """)

        #expect(installedShortcutNames == ["Morning Brief", "Ship Pace", "Open Raycast"])
        #expect(PaceActionExecutor.shortcutList(
            installedShortcutNames,
            containsShortcutNamed: "ship pace"
        ))
        #expect(PaceActionExecutor.shortcutList(
            installedShortcutNames,
            containsShortcutNamed: "  Morning   Brief  "
        ))
        #expect(!PaceActionExecutor.shortcutList(
            installedShortcutNames,
            containsShortcutNamed: "Missing Shortcut"
        ))
    }

    @Test func mcpClientRefreshesConfiguredServerNamesFromProvider() async throws {
        final class MutableMCPConfigurationBox {
            var serverConfigurations: [String: PaceMCPServerConfiguration] = [:]
        }

        let configurationBox = MutableMCPConfigurationBox()
        let client = PaceMCPStdioClient(
            serverConfigurationsProvider: {
                configurationBox.serverConfigurations
            },
            requestTimeoutInSeconds: 1
        )

        #expect(client.configuredServerNames == [])

        configurationBox.serverConfigurations = [
            "altic": PaceMCPServerConfiguration(command: "/usr/bin/true")
        ]

        #expect(client.configuredServerNames == ["altic"])
    }

    @Test func clickCandidateSelectorUsesHighConfidenceShortcut() async throws {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 10, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.85,
                    expectStateChange: true
                ),
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 200, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save Draft",
                    confidence: 0.84,
                    expectStateChange: true
                )
            ],
            clickCount: 1
        )

        let selectedCandidate = candidateSet.bestCandidate(
            currentGlobalCursorPoint: CGPoint(x: 200, y: 20),
            screenCaptures: [],
            coordinateConverter: { location, _ in
                CGPoint(x: location.xInScreenshotPixels, y: location.yInScreenshotPixels)
            }
        )

        #expect(selectedCandidate?.location?.xInScreenshotPixels == 10)
    }

    @Test func clickCandidateSelectorUsesCursorProximityWhenConfidenceIsAmbiguous() async throws {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 10, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.7,
                    expectStateChange: true
                ),
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 200, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.65,
                    expectStateChange: true
                )
            ],
            clickCount: 1
        )

        let selectedCandidate = candidateSet.bestCandidate(
            currentGlobalCursorPoint: CGPoint(x: 205, y: 20),
            screenCaptures: [],
            coordinateConverter: { location, _ in
                CGPoint(x: location.xInScreenshotPixels, y: location.yInScreenshotPixels)
            }
        )

        #expect(selectedCandidate?.location?.xInScreenshotPixels == 200)
    }

    @Test func clickCandidateOrderingKeepsFallbackCandidatesAfterBestMatch() async throws {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 20, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.68,
                    expectStateChange: true
                ),
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 210, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.64,
                    expectStateChange: true
                ),
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 400, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.20,
                    expectStateChange: true
                )
            ],
            clickCount: 1
        )

        let orderedCandidates = candidateSet.orderedCandidates(
            currentGlobalCursorPoint: CGPoint(x: 205, y: 20),
            screenCaptures: [],
            coordinateConverter: { location, _ in
                CGPoint(x: location.xInScreenshotPixels, y: location.yInScreenshotPixels)
            }
        )

        #expect(orderedCandidates.compactMap { $0.location?.xInScreenshotPixels } == [210, 20, 400])
    }

    @Test func clickCandidateSelectorUsesRecencyWhenConfidenceIsAmbiguous() async throws {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 10, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.68,
                    expectStateChange: true
                ),
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 300, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.64,
                    expectStateChange: true,
                    recency: PaceClickCandidateRecency(rank: 0, lastSeenMillisecondsAgo: nil)
                )
            ],
            clickCount: 1
        )

        let selectedCandidate = candidateSet.bestCandidate(
            currentGlobalCursorPoint: nil,
            screenCaptures: [],
            coordinateConverter: { location, _ in
                CGPoint(x: location.xInScreenshotPixels, y: location.yInScreenshotPixels)
            }
        )

        #expect(selectedCandidate?.location?.xInScreenshotPixels == 300)
    }

    @Test func clickCandidateSelectorUsesFocusedWindowWhenConfidenceIsAmbiguous() async throws {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 10, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.70,
                    expectStateChange: true
                ),
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 310, yInScreenshotPixels: 220, screenNumber: nil),
                    label: "Save",
                    confidence: 0.64,
                    expectStateChange: true
                )
            ],
            clickCount: 1
        )

        let selectedCandidate = candidateSet.bestCandidate(
            currentGlobalCursorPoint: nil,
            focusedWindowGlobalFrame: CGRect(x: 250, y: 180, width: 200, height: 140),
            screenCaptures: [],
            coordinateConverter: { location, _ in
                CGPoint(x: location.xInScreenshotPixels, y: location.yInScreenshotPixels)
            }
        )

        #expect(selectedCandidate?.location?.xInScreenshotPixels == 310)
    }

    @Test func clickCandidateExecutionReportsFailureWhenAllCandidatesFail() async throws {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 10, yInScreenshotPixels: 20, screenNumber: 99),
                    label: "Missing button",
                    confidence: 0.7,
                    expectStateChange: true
                )
            ],
            clickCount: 1
        )

        let observations = await executor.executeActionPlan(
            PaceActionExecutionPlan.serial(actions: [.clickCandidates(candidateSet)]),
            screenCaptures: []
        )

        #expect(observations.count == 1)
        #expect(observations.first?.toolName == "click_candidates")
        #expect(observations.first?.summary.contains("Click failed after trying 1 of 1 candidate") == true)
        #expect(observations.first?.summary.contains("\"Missing button\"") == true)
    }

    @Test func axLabelResolverNormalizesCommonSeparators() async throws {
        #expect(PaceAXLabelPressResolver.normalizeLabel("Save_Draft-now") == "save draft now")
    }
}
