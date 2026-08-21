import Foundation

public enum PacePersonalApplication: String, Codable, CaseIterable, Identifiable, Sendable {
    case calorie
    case kith

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .calorie: "Calorie"
        case .kith: "Kith"
        }
    }
}

public enum PaceConnectorState: String, Codable, Sendable {
    case current
    case stale
    case unavailable
}

public struct PaceSourceReference: Codable, Equatable, Sendable {
    public let application: PacePersonalApplication
    public let generatedAt: Date
    public let connectorState: PaceConnectorState
    public let provenance: String
    public let deepLink: URL

    public init(
        application: PacePersonalApplication,
        generatedAt: Date,
        connectorState: PaceConnectorState,
        provenance: String,
        deepLink: URL
    ) {
        self.application = application
        self.generatedAt = generatedAt
        self.connectorState = connectorState
        self.provenance = provenance
        self.deepLink = deepLink
    }
}

public struct PaceCalorieSummary: Codable, Equatable, Sendable {
    public let date: String
    public let calories: Double
    public let proteinGrams: Double
    public let proteinTargetLowGrams: Double?
    public let proteinTargetHighGrams: Double?
    public let waterMillilitres: Double
    public let waterTargetMillilitres: Double?
    public let suggestedFoodID: String?
    public let suggestedFoodName: String?
    public let suggestedFoodAmount: Double?

    public init(
        date: String,
        calories: Double,
        proteinGrams: Double,
        proteinTargetLowGrams: Double?,
        proteinTargetHighGrams: Double?,
        waterMillilitres: Double,
        waterTargetMillilitres: Double?,
        suggestedFoodID: String?,
        suggestedFoodName: String?,
        suggestedFoodAmount: Double?
    ) {
        self.date = date
        self.calories = calories
        self.proteinGrams = proteinGrams
        self.proteinTargetLowGrams = proteinTargetLowGrams
        self.proteinTargetHighGrams = proteinTargetHighGrams
        self.waterMillilitres = waterMillilitres
        self.waterTargetMillilitres = waterTargetMillilitres
        self.suggestedFoodID = suggestedFoodID
        self.suggestedFoodName = suggestedFoodName
        self.suggestedFoodAmount = suggestedFoodAmount
    }
}

public struct PaceKithPersonAttention: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let circle: String
    public let closeness: Int
    public let lastInteractionAt: Date?
    public let daysSinceInteraction: Int?
    public let attentionAfterDays: Int
    public let attentionRequired: Bool

    public init(
        id: UUID,
        name: String,
        circle: String,
        closeness: Int,
        lastInteractionAt: Date?,
        daysSinceInteraction: Int?,
        attentionAfterDays: Int,
        attentionRequired: Bool
    ) {
        self.id = id
        self.name = name
        self.circle = circle
        self.closeness = closeness
        self.lastInteractionAt = lastInteractionAt
        self.daysSinceInteraction = daysSinceInteraction
        self.attentionAfterDays = attentionAfterDays
        self.attentionRequired = attentionRequired
    }
}

public struct PaceKithSummary: Codable, Equatable, Sendable {
    public let people: [PaceKithPersonAttention]
    public let attentionRequired: [PaceKithPersonAttention]

    public init(
        people: [PaceKithPersonAttention],
        attentionRequired: [PaceKithPersonAttention]
    ) {
        self.people = people
        self.attentionRequired = attentionRequired
    }
}

public enum PaceDomainSummary: Codable, Equatable, Sendable {
    case calorie(PaceCalorieSummary)
    case kith(PaceKithSummary)
}

public struct PaceApplicationSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let source: PaceSourceReference
    public let status: String
    public let alerts: [String]
    public let suggestedAction: PaceAvailableAction?
    public let domain: PaceDomainSummary

    public var id: PacePersonalApplication { source.application }

    public init(
        schemaVersion: Int = 1,
        source: PaceSourceReference,
        status: String,
        alerts: [String],
        suggestedAction: PaceAvailableAction?,
        domain: PaceDomainSummary
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.status = status
        self.alerts = alerts
        self.suggestedAction = suggestedAction
        self.domain = domain
    }
}

public enum PaceActionConfirmationStatus: String, Codable, Sendable {
    case notRequired
    case requested
    case confirmed
    case declined
}

public enum PaceActionStatus: String, Codable, Sendable {
    case pending
    case succeeded
    case failed
    case undone
}

public enum PaceValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)
    case null
}

public struct PaceAvailableAction: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let title: String
    public let arguments: [String: PaceValue]
    public let requiresConfirmation: Bool

    public var id: String { name }

    public init(
        name: String,
        title: String,
        arguments: [String: PaceValue] = [:],
        requiresConfirmation: Bool = false
    ) {
        self.name = name
        self.title = title
        self.arguments = arguments
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct PaceActionRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceApplication: PacePersonalApplication
    public let requestedAt: Date
    public let originalInstruction: String
    public let confirmationStatus: PaceActionConfirmationStatus
    public let action: PaceAvailableAction

    public init(
        id: UUID = UUID(),
        sourceApplication: PacePersonalApplication,
        requestedAt: Date = Date(),
        originalInstruction: String,
        confirmationStatus: PaceActionConfirmationStatus,
        action: PaceAvailableAction
    ) {
        self.id = id
        self.sourceApplication = sourceApplication
        self.requestedAt = requestedAt
        self.originalInstruction = originalInstruction
        self.confirmationStatus = confirmationStatus
        self.action = action
    }
}

public struct PaceUndoInformation: Codable, Equatable, Sendable {
    public let action: PaceAvailableAction
    public let expiresAt: Date?

    public init(action: PaceAvailableAction, expiresAt: Date? = nil) {
        self.action = action
        self.expiresAt = expiresAt
    }
}

public struct PaceActionResult: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let actionID: UUID
    public let sourceApplication: PacePersonalApplication
    public let occurredAt: Date?
    public let status: PaceActionStatus
    public let message: String
    public let undoInformation: PaceUndoInformation?

    public init(
        id: UUID = UUID(),
        actionID: UUID,
        sourceApplication: PacePersonalApplication,
        occurredAt: Date?,
        status: PaceActionStatus,
        message: String,
        undoInformation: PaceUndoInformation?
    ) {
        self.id = id
        self.actionID = actionID
        self.sourceApplication = sourceApplication
        self.occurredAt = occurredAt
        self.status = status
        self.message = message
        self.undoInformation = undoInformation
    }
}

public struct PaceActivityRecord: Codable, Equatable, Identifiable, Sendable {
    public let request: PaceActionRequest
    public let result: PaceActionResult

    public var id: UUID { request.id }

    public init(request: PaceActionRequest, result: PaceActionResult) {
        self.request = request
        self.result = result
    }
}
