import Foundation
import PersonalSyncKit

actor PacePersonalPlatformConnector {
    static let productionBaseURL = URL(string: "https://personal-platform.significanthobbies.com")!
    static let calorieBaseURL = URL(string: "https://calorie.significanthobbies.com")!

    private let client: PersonalPlatformClient
    private let calendar: Calendar

    init(
        client: PersonalPlatformClient? = nil,
        calendar: Calendar = .current
    ) {
        self.calendar = calendar
        self.client = client ?? PersonalPlatformClient(
            configuration: PersonalPlatformConfiguration(
                platformBaseURL: Self.productionBaseURL,
                calorieBaseURL: Self.calorieBaseURL
            ),
            sessionStore: KeychainPersonalSessionStore(
                service: "com.pace.app.personal-platform"
            )
        )
    }

    func restoreConnection() async -> PaceConnectionsSnapshot {
        do {
            guard let session = try await client.restoreSession() else {
                return .disconnected
            }
            let response: ConnectionsResponse = try await client.get(path: "/v1/connections")
            return PaceConnectionsSnapshot(
                isConnected: true,
                identityEmail: response.identity.email,
                scopes: response.scopes.map(\.rawValue),
                kithSynchronizedAt: response.freshness.kith.synchronizedAt,
                calorieSynchronizedAt: response.freshness.calorie.synchronizedAt,
                message: session.isExpired ? "Reconnect to continue." : "Connected with Apple"
            )
        } catch {
            return PaceConnectionsSnapshot(
                isConnected: false,
                identityEmail: nil,
                scopes: [],
                kithSynchronizedAt: nil,
                calorieSynchronizedAt: nil,
                message: error.localizedDescription
            )
        }
    }

    func connect(with credential: AppleIdentityCredential, deviceID: UUID) async throws {
        _ = try await client.signInWithApple(
            credential,
            device: PersonalDevice(
                id: deviceID,
                application: .pace,
                platform: .macOS,
                displayName: Host.current().localizedName ?? "Pace on Mac"
            ),
            scopes: [.lifeRead, .calorieRead, .calorieWrite, .kithRead, .kithWrite]
        )
    }

    func disconnect() async {
        await client.signOut()
    }

    func getSnapshots() async -> [PacePersonalApplication: PaceApplicationSnapshot] {
        guard (try? await client.restoreSession()) != nil else {
            return disconnectedSnapshots()
        }
        do {
            let response: LifeTodayResponse = try await client.get(
                path: "/v1/life/today?date=\(dateKey())&timezone=\(encodedTimeZone)",
                includesCalorieCredential: true
            )
            return [
                .calorie: calorieSnapshot(response.sources.calorie),
                .kith: kithSnapshot(response.sources.kith),
            ]
        } catch {
            return unavailableSnapshots(message: error.localizedDescription)
        }
    }

    func execute(_ request: PaceActionRequest) async -> PaceActionResult {
        do {
            let response: ToolActionResponse
            switch request.action.name {
            case "calorie.log_food":
                guard
                    let foodID = request.action.arguments["food_id"]?.stringValue,
                    let foodName = request.action.arguments["food_name"]?.stringValue
                else {
                    return failure(for: request, message: "Choose one exact saved Calorie food.")
                }
                response = try await client.send(
                    path: "/v1/actions/calorie/log-food",
                    body: CalorieLogFoodRequest(
                        foodId: foodID,
                        foodName: foodName,
                        amount: request.action.arguments["amount"]?.numberValue,
                        idempotencyKey: request.id.uuidString.lowercased(),
                        originalInstruction: request.originalInstruction
                    ),
                    includesCalorieCredential: true
                )
            case "kith.record_interaction":
                guard
                    let personName = request.action.arguments["person_name"]?.stringValue,
                    let body = request.action.arguments["body"]?.stringValue
                else {
                    return failure(for: request, message: "Choose one Kith person and interaction note.")
                }
                response = try await client.send(
                    path: "/v1/actions/kith/record-interaction",
                    body: KithRecordInteractionRequest(
                        personName: personName,
                        kind: request.action.arguments["kind"]?.stringValue ?? "note",
                        body: body,
                        idempotencyKey: request.id.uuidString.lowercased(),
                        originalInstruction: request.originalInstruction
                    )
                )
            case "life.undo":
                guard let actionID = request.action.arguments["action_id"]?.stringValue else {
                    return failure(for: request, message: "The Personal Platform action is missing.")
                }
                response = try await client.send(
                    path: "/v1/actions/\(actionID)/undo",
                    body: EmptyRequest(),
                    includesCalorieCredential: request.sourceApplication == .calorie
                )
            default:
                return failure(for: request, message: "That domain action is not available in Pace.")
            }
            return map(response, request: request)
        } catch {
            return failure(for: request, message: error.localizedDescription)
        }
    }

    func recentActivity() async -> [PaceActivityRecord] {
        do {
            let response: ActivityResponse = try await client.get(path: "/v1/life/recent-activity?limit=100")
            return response.actions.compactMap(mapAudit)
        } catch {
            return []
        }
    }

    private var encodedTimeZone: String {
        calendar.timeZone.identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "UTC"
    }

    private func dateKey(_ now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    private func calorieSnapshot(_ source: SourceResult<CalorieSource>) -> PaceApplicationSnapshot {
        guard source.status == "current", let value = source.value else {
            return unavailableSnapshot(
                application: .calorie,
                status: "Calorie is unavailable",
                alert: source.message ?? "Reconnect Calorie through Personal Platform."
            )
        }
        let dashboard = value.dashboard
        let suggestedFood = dashboard.foods.first
        let proteinLow = dashboard.target.proteinRangeG?.first
        let shortfall = max(0, (proteinLow ?? 0) - dashboard.totals.proteinG)
        return PaceApplicationSnapshot(
            source: PaceSourceReference(
                application: .calorie,
                generatedAt: value.synchronizedAt,
                connectorState: .current,
                provenance: value.provenance,
                deepLink: Self.calorieBaseURL.appendingPathComponent("app/")
            ),
            status: shortfall > 0
                ? "\(whole(shortfall)) g protein below target"
                : "Protein target covered",
            alerts: shortfall > 0 ? ["Protein is below the lower daily target"] : [],
            suggestedAction: suggestedFood.map {
                PaceAvailableAction(
                    name: "calorie.log_food",
                    title: "Log \($0.name)",
                    arguments: [
                        "food_id": .string($0.id),
                        "food_name": .string($0.name),
                        "amount": .number($0.defaultAmount),
                    ]
                )
            },
            domain: .calorie(
                PaceCalorieSummary(
                    date: dashboard.date,
                    calories: dashboard.totals.calories,
                    proteinGrams: dashboard.totals.proteinG,
                    proteinTargetLowGrams: proteinLow,
                    proteinTargetHighGrams: dashboard.target.proteinRangeG?.dropFirst().first,
                    waterMillilitres: dashboard.totals.waterMl,
                    waterTargetMillilitres: dashboard.profile.waterTargetMl,
                    suggestedFoodID: suggestedFood?.id,
                    suggestedFoodName: suggestedFood?.name,
                    suggestedFoodAmount: suggestedFood?.defaultAmount
                )
            )
        )
    }

    private func kithSnapshot(_ source: SourceResult<KithSource>) -> PaceApplicationSnapshot {
        guard source.status == "current", let value = source.value else {
            return unavailableSnapshot(
                application: .kith,
                status: "Kith is unavailable",
                alert: source.message ?? "Open Kith on iPhone and synchronize."
            )
        }
        let people = value.people.map(\.paceValue)
        let attention = value.attentionRequired.map(\.paceValue)
        let first = attention.first
        return PaceApplicationSnapshot(
            source: PaceSourceReference(
                application: .kith,
                generatedAt: value.synchronizedAt ?? Date.distantPast,
                connectorState: value.synchronizedAt == nil ? .stale : .current,
                provenance: value.provenance,
                deepLink: URL(string: "kith://people")!
            ),
            status: attention.isEmpty
                ? "No relationship follow-up is due"
                : "\(attention.count) relationship follow-up\(attention.count == 1 ? "" : "s") due",
            alerts: first.map { ["\($0.name) is ready for attention"] } ?? [],
            suggestedAction: first.map {
                PaceAvailableAction(
                    name: "kith.record_interaction",
                    title: "Record a check-in with \($0.name)",
                    arguments: [
                        "person_name": .string($0.name),
                        "kind": .string("note"),
                        "body": .string("Spoke today."),
                    ]
                )
            },
            domain: .kith(PaceKithSummary(people: people, attentionRequired: attention))
        )
    }

    private func map(_ response: ToolActionResponse, request: PaceActionRequest) -> PaceActionResult {
        let backendActionID = UUID(uuidString: response.actionId) ?? request.id
        return PaceActionResult(
            actionID: request.id,
            sourceApplication: PacePersonalApplication(rawValue: response.domain) ?? request.sourceApplication,
            occurredAt: response.occurredAt,
            status: PaceActionStatus(rawValue: response.status) ?? .failed,
            message: response.message,
            undoInformation: response.undo == nil
                ? nil
                : PaceUndoInformation(
                    action: PaceAvailableAction(
                        name: "life.undo",
                        title: "Undo",
                        arguments: ["action_id": .string(backendActionID.uuidString.lowercased())]
                    ),
                    expiresAt: response.undo?.expiresAt
                )
        )
    }

    private func mapAudit(_ audit: AuditResponse) -> PaceActivityRecord? {
        guard
            let actionID = UUID(uuidString: audit.id),
            let application = PacePersonalApplication(rawValue: audit.domain),
            let status = PaceActionStatus(rawValue: audit.status)
        else { return nil }
        let request = PaceActionRequest(
            id: actionID,
            sourceApplication: application,
            requestedAt: audit.createdAt,
            originalInstruction: audit.originalInstruction,
            confirmationStatus: .notRequired,
            action: PaceAvailableAction(name: audit.toolName, title: audit.originalInstruction)
        )
        let result = PaceActionResult(
            actionID: actionID,
            sourceApplication: application,
            occurredAt: audit.completedAt,
            status: status,
            message: audit.errorMessage ?? audit.originalInstruction,
            undoInformation: audit.undoPayload == nil || audit.undoneAt != nil
                ? nil
                : PaceUndoInformation(
                    action: PaceAvailableAction(
                        name: "life.undo",
                        title: "Undo",
                        arguments: ["action_id": .string(audit.id)]
                    )
                )
        )
        return PaceActivityRecord(request: request, result: result)
    }

    private func disconnectedSnapshots() -> [PacePersonalApplication: PaceApplicationSnapshot] {
        [
            .calorie: unavailableSnapshot(
                application: .calorie,
                status: "Connect Personal Platform",
                alert: "Sign in with Apple to read Calorie through its domain service."
            ),
            .kith: unavailableSnapshot(
                application: .kith,
                status: "Connect Personal Platform",
                alert: "Use the same Apple identity as Kith on iPhone."
            ),
        ]
    }

    private func unavailableSnapshots(message: String) -> [PacePersonalApplication: PaceApplicationSnapshot] {
        Dictionary(uniqueKeysWithValues: PacePersonalApplication.allCases.map {
            ($0, unavailableSnapshot(application: $0, status: "Temporarily unavailable", alert: message))
        })
    }

    private func unavailableSnapshot(
        application: PacePersonalApplication,
        status: String,
        alert: String
    ) -> PaceApplicationSnapshot {
        let domain: PaceDomainSummary = application == .calorie
            ? .calorie(
                PaceCalorieSummary(
                    date: dateKey(),
                    calories: 0,
                    proteinGrams: 0,
                    proteinTargetLowGrams: nil,
                    proteinTargetHighGrams: nil,
                    waterMillilitres: 0,
                    waterTargetMillilitres: nil,
                    suggestedFoodID: nil,
                    suggestedFoodName: nil,
                    suggestedFoodAmount: nil
                )
            )
            : .kith(PaceKithSummary(people: [], attentionRequired: []))
        return PaceApplicationSnapshot(
            source: PaceSourceReference(
                application: application,
                generatedAt: Date.distantPast,
                connectorState: .unavailable,
                provenance: "No current Personal Platform response",
                deepLink: application == .calorie
                    ? Self.calorieBaseURL.appendingPathComponent("app/")
                    : URL(string: "kith://people")!
            ),
            status: status,
            alerts: [alert],
            suggestedAction: nil,
            domain: domain
        )
    }

    private func failure(for request: PaceActionRequest, message: String) -> PaceActionResult {
        PaceActionResult(
            actionID: request.id,
            sourceApplication: request.sourceApplication,
            occurredAt: nil,
            status: .failed,
            message: message,
            undoInformation: nil
        )
    }

    private func whole(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

struct PaceConnectionsSnapshot: Equatable, Sendable {
    let isConnected: Bool
    let identityEmail: String?
    let scopes: [String]
    let kithSynchronizedAt: Date?
    let calorieSynchronizedAt: Date?
    let message: String

    static let disconnected = PaceConnectionsSnapshot(
        isConnected: false,
        identityEmail: nil,
        scopes: [],
        kithSynchronizedAt: nil,
        calorieSynchronizedAt: nil,
        message: "Not connected"
    )
}

private struct SourceResult<Value: Decodable & Sendable>: Decodable, Sendable {
    let status: String
    let value: Value?
    let message: String?
}

private struct LifeTodayResponse: Decodable, Sendable {
    struct Sources: Decodable, Sendable {
        let calorie: SourceResult<CalorieSource>
        let kith: SourceResult<KithSource>
    }
    let sources: Sources
}

private struct CalorieSource: Decodable, Sendable {
    let synchronizedAt: Date
    let provenance: String
    let dashboard: CalorieDashboard
}

private struct CalorieDashboard: Decodable, Sendable {
    struct Profile: Decodable, Sendable { let waterTargetMl: Double? }
    struct Food: Decodable, Sendable {
        let id: String
        let name: String
        let defaultAmount: Double
    }
    struct Totals: Decodable, Sendable {
        let calories: Double
        let proteinG: Double
        let waterMl: Double
    }
    struct Target: Decodable, Sendable { let proteinRangeG: [Double]? }
    let profile: Profile
    let foods: [Food]
    let totals: Totals
    let target: Target
    let date: String
}

private struct KithSource: Decodable, Sendable {
    let synchronizedAt: Date?
    let provenance: String
    let people: [KithPerson]
    let attentionRequired: [KithPerson]
}

private struct KithPerson: Decodable, Sendable {
    let id: UUID
    let name: String
    let circle: String
    let closeness: Int
    let lastInteractionAt: Date?
    let daysSinceInteraction: Int?
    let attentionAfterDays: Int
    let attentionRequired: Bool

    var paceValue: PaceKithPersonAttention {
        PaceKithPersonAttention(
            id: id,
            name: name,
            circle: circle,
            closeness: closeness,
            lastInteractionAt: lastInteractionAt,
            daysSinceInteraction: daysSinceInteraction,
            attentionAfterDays: attentionAfterDays,
            attentionRequired: attentionRequired
        )
    }
}

private struct ConnectionsResponse: Decodable, Sendable {
    struct Freshness: Decodable, Sendable {
        struct Source: Decodable, Sendable { let synchronizedAt: Date? }
        let kith: Source
        let calorie: Source
    }
    let identity: PersonalIdentity
    let scopes: [PersonalPlatformScope]
    let freshness: Freshness
}

private struct CalorieLogFoodRequest: Encodable, Sendable {
    let foodId: String
    let foodName: String
    let amount: Double?
    let idempotencyKey: String
    let originalInstruction: String
}

private struct KithRecordInteractionRequest: Encodable, Sendable {
    let personName: String
    let kind: String
    let body: String
    let idempotencyKey: String
    let originalInstruction: String
}

private struct EmptyRequest: Encodable, Sendable {}

private struct ToolActionResponse: Decodable, Sendable {
    struct Undo: Decodable, Sendable { let actionId: String; let expiresAt: Date? }
    let actionId: String
    let domain: String
    let toolName: String
    let status: String
    let occurredAt: Date?
    let message: String
    let undo: Undo?
}

private struct ActivityResponse: Decodable, Sendable {
    let actions: [AuditResponse]
}

private struct AuditResponse: Decodable, Sendable {
    let id: String
    let domain: String
    let toolName: String
    let originalInstruction: String
    let status: String
    let createdAt: Date
    let completedAt: Date?
    let undoPayload: String?
    let undoneAt: Date?
    let errorMessage: String?
}

extension PaceValue {
    fileprivate var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    fileprivate var numberValue: Double? {
        switch self {
        case let .number(value): value
        case let .integer(value): Double(value)
        default: nil
        }
    }
}
