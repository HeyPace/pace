//
//  PaceShortcutsAutomationProvider.swift
//  leanring-buddy
//
//  Local discovery and deterministic command routing for automations owned by
//  the macOS Shortcuts app. Shortcut names stay on-device and never enter a
//  planner prompt.
//

import Foundation

nonisolated struct PaceShortcutsCommandResult: Sendable {
    let output: String
    let errorOutput: String
    let terminationStatus: Int32

    var failureSummary: String {
        let trimmedErrorOutput = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedErrorOutput.isEmpty {
            return trimmedErrorOutput
        }

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOutput.isEmpty {
            return trimmedOutput
        }

        return "command exited with status \(terminationStatus)"
    }
}

nonisolated enum PaceShortcutsCommandRunner {
    static func run(
        arguments: [String],
        timeout: TimeInterval
    ) async -> PaceShortcutsCommandResult {
        let commandTask = Task.detached(priority: .userInitiated) {
            runSynchronously(arguments: arguments, timeout: timeout)
        }

        return await withTaskCancellationHandler {
            await commandTask.value
        } onCancel: {
            commandTask.cancel()
        }
    }

    private static func runSynchronously(
        arguments: [String],
        timeout: TimeInterval
    ) -> PaceShortcutsCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        do {
            try process.run()
        } catch {
            return PaceShortcutsCommandResult(
                output: "",
                errorOutput: error.localizedDescription,
                terminationStatus: 1
            )
        }

        let commandDeadline = Date().addingTimeInterval(max(0.1, timeout))
        var forcedFailureDescription: String?
        while process.isRunning {
            if Task.isCancelled {
                forcedFailureDescription = "Shortcuts command was cancelled."
                process.terminate()
                break
            }
            if Date() >= commandDeadline {
                forcedFailureDescription = "Shortcuts command timed out."
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()

        let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let standardErrorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
        let standardOutput = String(data: standardOutputData, encoding: .utf8) ?? ""
        let standardError = String(data: standardErrorData, encoding: .utf8) ?? ""

        if let forcedFailureDescription {
            return PaceShortcutsCommandResult(
                output: standardOutput,
                errorOutput: forcedFailureDescription,
                terminationStatus: 1
            )
        }

        return PaceShortcutsCommandResult(
            output: standardOutput,
            errorOutput: standardError,
            terminationStatus: process.terminationStatus
        )
    }
}

nonisolated struct PaceShortcutAutomationCatalog: Equatable, Sendable {
    let shortcutNames: [String]

    private let shortcutNamesByNormalizedName: [String: String]

    init(shortcutNames rawShortcutNames: [String]) {
        var uniqueShortcutNamesByNormalizedName: [String: String] = [:]

        for rawShortcutName in rawShortcutNames {
            let trimmedShortcutName = rawShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedShortcutName = Self.normalizedName(trimmedShortcutName)
            guard !normalizedShortcutName.isEmpty else {
                continue
            }

            if uniqueShortcutNamesByNormalizedName[normalizedShortcutName] == nil {
                uniqueShortcutNamesByNormalizedName[normalizedShortcutName] = trimmedShortcutName
            }
        }

        let sortedShortcutNames = uniqueShortcutNamesByNormalizedName.values.sorted { firstName, secondName in
            let firstNormalizedName = Self.normalizedName(firstName)
            let secondNormalizedName = Self.normalizedName(secondName)
            if firstNormalizedName == secondNormalizedName {
                return firstName < secondName
            }
            return firstNormalizedName < secondNormalizedName
        }

        self.shortcutNames = sortedShortcutNames
        self.shortcutNamesByNormalizedName = Dictionary(
            uniqueKeysWithValues: sortedShortcutNames.map { shortcutName in
                (Self.normalizedName(shortcutName), shortcutName)
            }
        )
    }

    func exactDisplayName(matching requestedShortcutName: String) -> String? {
        shortcutNamesByNormalizedName[Self.normalizedName(requestedShortcutName)]
    }

    static func normalizedName(_ shortcutName: String) -> String {
        shortcutName
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func fromListOutput(_ listOutput: String) -> PaceShortcutAutomationCatalog {
        PaceShortcutAutomationCatalog(
            shortcutNames: listOutput.components(separatedBy: .newlines)
        )
    }
}

nonisolated enum PaceShortcutCatalogDiscoveryResult: Equatable, Sendable {
    case success(PaceShortcutAutomationCatalog)
    case failure(String)
}

nonisolated enum PaceShortcutCommand: Equatable, Sendable {
    case list
    case run(requestedShortcutName: String)
}

nonisolated enum PaceShortcutCommandParser {
    private static let listCommands: Set<String> = [
        "list shortcuts",
        "list my shortcuts",
        "show shortcuts",
        "show my shortcuts",
        "what shortcuts do i have",
        "which shortcuts do i have",
    ]

    static func parse(_ transcript: String) -> PaceShortcutCommand? {
        let cleanedTranscript = cleanedCommandText(transcript)
        let normalizedTranscript = PaceShortcutAutomationCatalog.normalizedName(cleanedTranscript)
        guard !normalizedTranscript.isEmpty else {
            return nil
        }

        if listCommands.contains(normalizedTranscript) {
            return .list
        }

        let shortcutFirstPrefixes = [
            "run the shortcut named ",
            "run shortcut named ",
            "run the shortcut ",
            "run shortcut ",
            "execute the shortcut ",
            "execute shortcut ",
            "use the shortcut ",
            "use shortcut ",
        ]
        for shortcutFirstPrefix in shortcutFirstPrefixes {
            if let requestedShortcutName = suffixAfterPrefix(
                shortcutFirstPrefix,
                in: cleanedTranscript
            ) {
                return .run(requestedShortcutName: requestedShortcutName)
            }
        }

        let actionFirstPrefixes = ["run ", "execute "]
        for actionFirstPrefix in actionFirstPrefixes {
            guard let commandBody = suffixAfterPrefix(actionFirstPrefix, in: cleanedTranscript),
                  let requestedShortcutName = removingShortcutSuffix(from: commandBody) else {
                continue
            }

            return .run(requestedShortcutName: removingLeadingArticle(from: requestedShortcutName))
        }

        return nil
    }

    static func fastActionParseResult(for shortcutDisplayName: String) -> PaceFastActionParseResult {
        PaceFastActionParseResult(
            spokenText: "running \(shortcutDisplayName).",
            executionPlan: .serial(actions: [.runShortcut(shortcutDisplayName)])
        )
    }

    private static func cleanedCommandText(_ transcript: String) -> String {
        transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func suffixAfterPrefix(_ prefix: String, in text: String) -> String? {
        guard let prefixRange = text.range(
            of: prefix,
            options: [.caseInsensitive, .anchored]
        ) else {
            return nil
        }

        let suffix = String(text[prefixRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }

    private static func removingShortcutSuffix(from text: String) -> String? {
        guard let shortcutSuffixRange = text.range(
            of: " shortcut",
            options: [.caseInsensitive, .anchored, .backwards]
        ), shortcutSuffixRange.upperBound == text.endIndex else {
            return nil
        }

        let requestedShortcutName = String(text[..<shortcutSuffixRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return requestedShortcutName.isEmpty ? nil : requestedShortcutName
    }

    private static func removingLeadingArticle(from text: String) -> String {
        for leadingArticle in ["my ", "the "] {
            if let suffix = suffixAfterPrefix(leadingArticle, in: text) {
                return suffix
            }
        }
        return text
    }
}

@MainActor
final class PaceShortcutsAutomationProvider {
    typealias CatalogLoader = () async -> PaceShortcutCatalogDiscoveryResult
    typealias CurrentDateProvider = () -> Date

    static let shared = PaceShortcutsAutomationProvider()

    private let successfulCatalogCacheDuration: TimeInterval
    private let currentDateProvider: CurrentDateProvider
    private let catalogLoader: CatalogLoader

    private var cachedCatalog: PaceShortcutAutomationCatalog?
    private var cachedCatalogDate: Date?
    private var catalogRefreshTask: Task<PaceShortcutCatalogDiscoveryResult, Never>?

    init(
        successfulCatalogCacheDuration: TimeInterval = 300,
        currentDateProvider: @escaping CurrentDateProvider = Date.init,
        catalogLoader: @escaping CatalogLoader = PaceShortcutsAutomationProvider.loadSystemCatalog
    ) {
        self.successfulCatalogCacheDuration = successfulCatalogCacheDuration
        self.currentDateProvider = currentDateProvider
        self.catalogLoader = catalogLoader
    }

    func catalog(forceRefresh: Bool = false) async -> PaceShortcutCatalogDiscoveryResult {
        if !forceRefresh, let cachedCatalog = cachedCatalogIfFresh() {
            return .success(cachedCatalog)
        }

        if let catalogRefreshTask {
            return await catalogRefreshTask.value
        }

        let refreshTask = Task { await catalogLoader() }
        catalogRefreshTask = refreshTask
        let discoveryResult = await refreshTask.value
        catalogRefreshTask = nil
        if case .success(let discoveredCatalog) = discoveryResult {
            cachedCatalog = discoveredCatalog
            cachedCatalogDate = currentDateProvider()
        }
        return discoveryResult
    }

    func cachedCatalogIfFresh() -> PaceShortcutAutomationCatalog? {
        guard let cachedCatalog,
              let cachedCatalogDate,
              currentDateProvider().timeIntervalSince(cachedCatalogDate)
                < successfulCatalogCacheDuration else {
            return nil
        }
        return cachedCatalog
    }

    private static func loadSystemCatalog() async -> PaceShortcutCatalogDiscoveryResult {
        let commandResult = await PaceShortcutsCommandRunner.run(
            arguments: ["list"],
            timeout: 10
        )
        guard commandResult.terminationStatus == 0 else {
            return .failure(Self.boundedFailureDescription(commandResult.failureSummary))
        }
        return .success(PaceShortcutAutomationCatalog.fromListOutput(commandResult.output))
    }

    private nonisolated static func boundedFailureDescription(_ failureDescription: String) -> String {
        let trimmedFailureDescription = failureDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFailureDescription.isEmpty {
            return "Shortcuts discovery failed."
        }
        return String(trimmedFailureDescription.prefix(300))
    }
}
