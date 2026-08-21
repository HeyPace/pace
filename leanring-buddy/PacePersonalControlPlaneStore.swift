import AppKit
import Combine
import Foundation
import PersonalSyncKit

@MainActor
final class PacePersonalControlPlaneStore: ObservableObject {
    static let shared = PacePersonalControlPlaneStore(
        connector: PacePersonalPlatformConnector(),
        activityJournal: PacePersonalActivityJournal(),
        workspace: .shared
    )

    @Published private(set) var snapshots: [PacePersonalApplication: PaceApplicationSnapshot] = [:]
    @Published private(set) var activity: [PaceActivityRecord]
    @Published private(set) var connections = PaceConnectionsSnapshot.disconnected
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAnswering = false
    @Published private(set) var answer: PacePersonalAnswer?
    @Published private(set) var connectionMessage: String?

    private let connector: PacePersonalPlatformConnector
    private let activityJournal: any PacePersonalActivityPersisting
    private let workspace: NSWorkspace

    init(
        connector: PacePersonalPlatformConnector,
        activityJournal: any PacePersonalActivityPersisting,
        workspace: NSWorkspace
    ) {
        self.connector = connector
        self.activityJournal = activityJournal
        self.workspace = workspace
        activity = activityJournal.load()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        async let latestSnapshots = connector.getSnapshots()
        async let latestConnections = connector.restoreConnection()
        async let latestActivity = connector.recentActivity()
        snapshots = await latestSnapshots
        connections = await latestConnections
        let remoteActivity = await latestActivity
        if !remoteActivity.isEmpty {
            activity = remoteActivity
            activityJournal.save(remoteActivity)
        }
        isRefreshing = false
    }

    func connect(with credential: AppleIdentityCredential) async {
        connectionMessage = "Connecting Personal Platform…"
        do {
            try await connector.connect(with: credential, deviceID: Self.deviceID())
            connectionMessage = "Calorie and Kith are connected through your Apple identity."
            await refresh()
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func disconnect() async {
        await connector.disconnect()
        connections = .disconnected
        connectionMessage = "Personal Platform disconnected from this Mac."
        await refresh()
    }

    func performSuggestedAction(for application: PacePersonalApplication) async {
        guard let snapshot = snapshots[application], let action = snapshot.suggestedAction else {
            openSourceApplication(application)
            return
        }
        await perform(action, for: application, instruction: action.title)
    }

    func undo(_ activityRecord: PaceActivityRecord) async {
        guard let undoInformation = activityRecord.result.undoInformation else { return }
        if let expiresAt = undoInformation.expiresAt, expiresAt < Date() { return }
        await perform(
            undoInformation.action,
            for: activityRecord.request.sourceApplication,
            instruction: "Undo: \(activityRecord.request.originalInstruction)"
        )
    }

    func ask(_ question: String) async {
        let instruction = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        isAnswering = true
        await refresh()

        if let command = PacePersonalCommandParser.parse(instruction, snapshots: snapshots) {
            var results: [PaceActionResult] = []
            for action in command.actions {
                let request = PaceActionRequest(
                    sourceApplication: action.application,
                    originalInstruction: instruction,
                    confirmationStatus: .notRequired,
                    action: action.action
                )
                let result = await connector.execute(request)
                record(request: request, result: result)
                results.append(result)
            }
            answer = PacePersonalAnswer(
                text: results.map { "\($0.sourceApplication.displayName): \($0.message)" }.joined(separator: "\n"),
                sources: command.actions.map(\.application),
                limitations: results.filter { $0.status == .failed }.map(\.message)
            )
            await refresh()
        } else {
            answer = PacePersonalCrossApplicationReasoner.answer(
                question: instruction,
                snapshots: snapshots
            )
        }
        isAnswering = false
    }

    func clearAnswer() {
        answer = nil
    }

    func openSourceApplication(_ application: PacePersonalApplication) {
        guard let deepLink = snapshots[application]?.source.deepLink else { return }
        workspace.open(deepLink)
    }

    private func perform(
        _ action: PaceAvailableAction,
        for application: PacePersonalApplication,
        instruction: String
    ) async {
        let request = PaceActionRequest(
            sourceApplication: application,
            originalInstruction: instruction,
            confirmationStatus: action.requiresConfirmation ? .confirmed : .notRequired,
            action: action
        )
        let result = await connector.execute(request)
        record(request: request, result: result)
        if result.status == .succeeded || result.status == .undone {
            await refresh()
        }
    }

    private func record(request: PaceActionRequest, result: PaceActionResult) {
        activity.removeAll { $0.request.id == request.id }
        activity.insert(PaceActivityRecord(request: request, result: result), at: 0)
        if activity.count > 250 { activity.removeLast(activity.count - 250) }
        activityJournal.save(activity)
    }

    private static func deviceID() -> UUID {
        let key = "personal-platform-device-id"
        if let stored = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) {
            return stored
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}

struct PacePersonalAnswer: Equatable, Sendable {
    let text: String
    let sources: [PacePersonalApplication]
    let limitations: [String]
}

enum PacePersonalCrossApplicationReasoner {
    static func answer(
        question: String,
        snapshots: [PacePersonalApplication: PaceApplicationSnapshot]
    ) -> PacePersonalAnswer {
        let relevantSources = PacePersonalQueryRouter.sources(for: question)
        let availableSources = relevantSources.filter {
            snapshots[$0]?.source.connectorState == .current
        }
        let limitations = relevantSources.compactMap { application -> String? in
            guard snapshots[application]?.source.connectorState != .current else { return nil }
            return "\(application.displayName) was unavailable, so Pace did not infer its state."
        }

        guard
            let calorieSnapshot = snapshots[.calorie],
            case let .calorie(calorie) = calorieSnapshot.domain,
            let kithSnapshot = snapshots[.kith],
            case let .kith(kith) = kithSnapshot.domain,
            availableSources.contains(.calorie),
            availableSources.contains(.kith)
        else {
            let availableText = availableSources.isEmpty
                ? "Neither connector has current data yet."
                : "I only have current data from \(availableSources.map(\.displayName).joined(separator: " and "))."
            return PacePersonalAnswer(
                text: "\(availableText) Connect or refresh the missing app before Pace combines them.",
                sources: availableSources,
                limitations: limitations
            )
        }

        let proteinRemaining = max(0, (calorie.proteinTargetLowGrams ?? 0) - calorie.proteinGrams)
        let nutrition = proteinRemaining > 0
            ? "You are \(wholeNumber(proteinRemaining)) g below your lower protein target."
            : "Your lower protein target is covered."
        let relationship: String
        if let person = kith.attentionRequired.first {
            relationship = "\(person.name) is the clearest Kith follow-up."
        } else {
            relationship = "Kith shows no relationship follow-up due."
        }
        let recommendation: String
        if let person = kith.attentionRequired.first, proteinRemaining > 0 {
            recommendation = "Contact \(person.name), then log \(calorie.suggestedFoodName ?? "your saved protein meal")."
        } else if let person = kith.attentionRequired.first {
            recommendation = "Nutrition is on track; contact \(person.name) next."
        } else if proteinRemaining > 0 {
            recommendation = "The clearest next step is \(calorie.suggestedFoodName ?? "a protein meal")."
        } else {
            recommendation = "Neither connected app shows an urgent next action."
        }
        return PacePersonalAnswer(
            text: "\(nutrition) \(relationship) \(recommendation)",
            sources: [.calorie, .kith],
            limitations: limitations
        )
    }

    private static func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

enum PacePersonalQueryRouter {
    static func sources(for question: String) -> [PacePersonalApplication] {
        let normalized = question.lowercased()
        let calorieTerms = ["food", "meal", "protein", "calorie", "water", "eat", "nutrition"]
        let kithTerms = ["person", "people", "relationship", "spoke", "contact", "follow up", "rahul"]
        var sources: [PacePersonalApplication] = []
        if calorieTerms.contains(where: normalized.contains) { sources.append(.calorie) }
        if kithTerms.contains(where: normalized.contains) { sources.append(.kith) }
        if sources.isEmpty || normalized.contains("today") || normalized.contains("attention") {
            return [.calorie, .kith]
        }
        return sources
    }
}

struct PacePersonalParsedCommand: Sendable {
    struct Item: Sendable {
        let application: PacePersonalApplication
        let action: PaceAvailableAction
    }
    let actions: [Item]
}

enum PacePersonalCommandParser {
    static func parse(
        _ instruction: String,
        snapshots: [PacePersonalApplication: PaceApplicationSnapshot]
    ) -> PacePersonalParsedCommand? {
        let normalized = instruction.lowercased()
        guard normalized.contains("record") || normalized.contains("log") else { return nil }
        var actions: [PacePersonalParsedCommand.Item] = []

        if normalized.contains("breakfast"),
           let calorie = snapshots[.calorie],
           case let .calorie(summary) = calorie.domain,
           let foodID = summary.suggestedFoodID,
           let foodName = summary.suggestedFoodName {
            actions.append(
                .init(
                    application: .calorie,
                    action: PaceAvailableAction(
                        name: "calorie.log_food",
                        title: "Log \(foodName)",
                        arguments: [
                            "food_id": .string(foodID),
                            "food_name": .string(foodName),
                            "amount": .number(summary.suggestedFoodAmount ?? 1),
                        ]
                    )
                )
            )
        }

        if let name = spokenPersonName(in: instruction),
           let kith = snapshots[.kith],
           case let .kith(summary) = kith.domain,
           let person = summary.people.first(where: {
               $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
           }) {
            actions.append(
                .init(
                    application: .kith,
                    action: PaceAvailableAction(
                        name: "kith.record_interaction",
                        title: "Record speaking to \(person.name)",
                        arguments: [
                            "person_name": .string(person.name),
                            "kind": .string("call"),
                            "body": .string("Spoke today."),
                        ]
                    )
                )
            )
        }
        return actions.isEmpty ? nil : PacePersonalParsedCommand(actions: actions)
    }

    private static func spokenPersonName(in instruction: String) -> String? {
        guard let range = instruction.range(of: "spoke to ", options: .caseInsensitive) else {
            return nil
        }
        let remainder = instruction[range.upperBound...]
        let end = remainder.firstIndex(where: { $0 == "," || $0 == "." })
            ?? remainder.range(of: " and ", options: .caseInsensitive)?.lowerBound
            ?? remainder.endIndex
        let value = remainder[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
