import Foundation

public enum PersonalPlatformScope: String, Codable, CaseIterable, Sendable {
    case lifeRead = "life:read"
    case calorieRead = "calorie:read"
    case calorieWrite = "calorie:write"
    case kithRead = "kith:read"
    case kithWrite = "kith:write"
}

public enum PersonalApplication: String, Codable, Sendable {
    case pace
    case kith
}

public enum PersonalClientPlatform: String, Codable, Sendable {
    case macOS = "macos"
    case iOS = "ios"
}

public struct PersonalDevice: Codable, Equatable, Sendable {
    public let id: UUID
    public let application: PersonalApplication
    public let platform: PersonalClientPlatform
    public let displayName: String

    public init(
        id: UUID,
        application: PersonalApplication,
        platform: PersonalClientPlatform,
        displayName: String
    ) {
        self.id = id
        self.application = application
        self.platform = platform
        self.displayName = displayName
    }
}

public struct PersonalIdentity: Codable, Equatable, Sendable {
    public let userId: UUID
    public let authUserId: String
    public let appleSubject: String
    public let email: String?
}

public struct PersonalPlatformSession: Codable, Equatable, Sendable {
    public let token: String
    public let calorieToken: String
    public let expiresAt: Date
    public let scopes: [PersonalPlatformScope]
    public let identity: PersonalIdentity

    public var isExpired: Bool { expiresAt <= Date() }
}

public struct AppleIdentityCredential: Equatable, Sendable {
    public let identityToken: String
    public let nonce: String
    public let email: String?
    public let firstName: String?
    public let lastName: String?

    public init(
        identityToken: String,
        nonce: String,
        email: String?,
        firstName: String?,
        lastName: String?
    ) {
        self.identityToken = identityToken
        self.nonce = nonce
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
    }
}

public struct PersonalSyncConflict: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let mutationID: UUID
    public let message: String
    public let recordedAt: Date

    public init(
        id: UUID = UUID(),
        mutationID: UUID,
        message: String,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.mutationID = mutationID
        self.message = message
        self.recordedAt = recordedAt
    }
}

public struct PersonalSyncMutation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let idempotencyKey: String
    public let body: Data
    public let createdAt: Date
    public var attemptCount: Int

    public init(
        id: UUID = UUID(),
        idempotencyKey: String,
        body: Data,
        createdAt: Date = Date(),
        attemptCount: Int = 0
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.body = body
        self.createdAt = createdAt
        self.attemptCount = attemptCount
    }
}

public struct PersonalSyncSnapshot: Codable, Equatable, Sendable {
    public var cursor: Int
    public var pendingMutations: [PersonalSyncMutation]
    public var conflicts: [PersonalSyncConflict]
    public var lastSynchronizedAt: Date?

    public init(
        cursor: Int = 0,
        pendingMutations: [PersonalSyncMutation] = [],
        conflicts: [PersonalSyncConflict] = [],
        lastSynchronizedAt: Date? = nil
    ) {
        self.cursor = cursor
        self.pendingMutations = pendingMutations
        self.conflicts = conflicts
        self.lastSynchronizedAt = lastSynchronizedAt
    }
}
