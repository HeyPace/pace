import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceDesktopRequestsTests {
    @Test func plannerCanComposeWorkAppsAndFolderSpecificCodexSession() {
        let result = PaceActionTagParser.parseActions(
            from: """
                {"spokenText":"Opening your workspace.","intent":"action","payload":{"calls":[
                  {"name":"App.launch","args":{"name":"Linear"}},
                  {"name":"App.launch","args":{"name":"Slack"}},
                  {"name":"App.launch","args":{"name":"Chrome","profile":"work"}},
                  {"name":"Codex.session","args":{"directory":"~/projects/example"}}
                ]}}
                """)
        #expect(result.actions.count == 4)
        guard result.actions.count == 4 else { return }
        guard case .openBrowser(let browser) = result.actions[2],
            case .codexSession(let session) = result.actions[3]
        else {
            Issue.record("Expected profile-aware browser and Codex session")
            return
        }
        #expect(browser.chromeProfile == "work")
        #expect(session.directory == "~/projects/example")
    }

    @Test func recordingModesRemainDistinctAndInvalidModesFailClosed() {
        let screen = PaceActionTagParser.parseActions(
            from:
                #"{"spokenText":"Opening controls.","intent":"action","payload":{"name":"screen_capture","args":{"mode":"recording"}}}"#
        )
        let meeting = PaceActionTagParser.parseActions(
            from:
                #"{"spokenText":"Recording audio.","intent":"action","payload":{"name":"meeting","args":{"action":"start"}}}"#
        )
        let invalid = PaceActionTagParser.parseActions(
            from:
                #"{"spokenText":"Bad mode.","intent":"action","payload":{"name":"screen_capture","args":{"mode":"everything"}}}"#
        )
        guard case .screenCapture(.recording) = screen.actions.first,
            case .meeting(.start(profileSlug: nil)) = meeting.actions.first
        else {
            Issue.record("Expected distinct screen and meeting actions")
            return
        }
        #expect(invalid.actions.isEmpty)
        #expect(PaceMeetingModeCommandParser.parse("start screen recording") == nil)
        #expect(PaceMeetingModeCommandParser.parse("start recording") == nil)
    }

    @Test func explicitCaptureModesDoNotRestoreThePreviousMode() {
        #expect(PaceScreenCaptureKind.screenshot.arguments == ["-i", "-U", "-J", "selection"])
        #expect(PaceScreenCaptureKind.recording.arguments == ["-i", "-U", "-J", "video"])
    }

    @Test func workProfileUsesSavedDirectoryAndExplicitBrowserIsHonored() {
        #expect(PaceBrowserOpenRequest.profileDirectory(for: "work", savedProfile: "Profile 1") == "Profile 1")
        #expect(PaceBrowserOpenRequest.profileDirectory(for: "Profile 2", savedProfile: "Profile 1") == "Profile 2")
        #expect(PaceBrowserOpenRequest.profileDirectory(for: "../../elsewhere", savedProfile: "Profile 1") == nil)
        let result = PaceFastActionCommandParser.parse(transcript: "open Hacker News in Chrome")
        guard case .openBrowser(let request) = result?.executionPlan.flattenedActions.first else {
            Issue.record("Expected explicit Chrome browser")
            return
        }
        #expect(request.url == "https://news.ycombinator.com")
    }

    @Test func warpConfigurationCannotTurnFolderOrExecutableIntoInjectedCommands() throws {
        let folder = URL(fileURLWithPath: "/tmp/a $(touch bad) ' quoted")
        let executable = URL(fileURLWithPath: "/tmp/codex's executable")
        let configuration = try PaceCodexSessionRequest.warpConfiguration(directory: folder, executable: executable)
        #expect(configuration.contains("directory = "))
        #expect(!configuration.contains(#"\/"#))
        #expect(configuration.contains("shell = \"zsh\""))
        let quotedExecutable = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encodedCommand = String(decoding: try encoder.encode(quotedExecutable), as: UTF8.self)
        #expect(configuration.contains("commands = [" + encodedCommand + "]"))
        #expect(!configuration.contains("cd "))
        #expect(PaceCodexSessionRequest(directory: "/unlikely-nonexistent-pace-folder").resolvedDirectory() == nil)
    }

    @Test func folderlessCodexRequestsClarifyInsteadOfReusingOldDirectories() {
        #expect(PaceCodexSessionRequest.needsDirectoryClarification("Start Codex in Warp."))
        #expect(PaceCodexSessionRequest.needsDirectoryClarification("Open a Codex session"))
        #expect(!PaceCodexSessionRequest.needsDirectoryClarification("Start Codex in Warp in /tmp"))
        #expect(!PaceCodexSessionRequest.needsDirectoryClarification("Start Codex in ~/Desktop/fleet/pace"))
        #expect(!PaceCodexSessionRequest.needsDirectoryClarification("Start Codex in the Pace project folder"))
        #expect(!PaceCodexSessionRequest.needsDirectoryClarification("Open Hacker News"))
    }

    @Test func foregroundCodexDoesNotInheritToolsOrRequireGitRepository() {
        let arguments = PaceLocalCLIPlannerClient.codexArguments(modelIdentifier: nil, isResearchTurn: false)
        #expect(arguments.contains("--skip-git-repo-check"))
        #expect(arguments.contains("--ignore-user-config"))
        #expect(arguments.contains("shell_tool"))
        #expect(arguments.contains("web_search=\"disabled\""))
        let directories = PaceLocalCLIPlannerClient.executableSearchDirectories(
            path: "/usr/bin", homeDirectory: URL(fileURLWithPath: "/Users/example"))
        #expect(directories.contains("/Users/example/.local/bin"))
    }
    @Test func codexComputerUsePromptRequestsFreshObservationsBeforeDependentActions() {
        let prompt = CompanionSystemPrompt.build(includeAgentMode: true, usesIterativeComputerUse: true)
        #expect(prompt.contains("Pace WILL call you again"))
        #expect(prompt.contains("Do not replay completed actions"))
        #expect(prompt.contains("codex_session"))
        let readOnlyPrompt = CompanionSystemPrompt.build(includeAgentMode: false, usesIterativeComputerUse: true)
        #expect(!readOnlyPrompt.contains("Pace WILL call you again"))
    }

}
