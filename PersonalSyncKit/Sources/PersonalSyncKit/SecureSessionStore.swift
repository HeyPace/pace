import Foundation
import Security

public protocol PersonalSessionStoring: Sendable {
    func load() async throws -> PersonalPlatformSession?
    func save(_ session: PersonalPlatformSession) async throws
    func delete() async throws
}

public actor KeychainPersonalSessionStore: PersonalSessionStoring {
    private let service: String
    private let account: String

    public init(service: String, account: String = "personal-platform-session") {
        self.service = service
        self.account = account
    }

    public func load() throws -> PersonalPlatformSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PersonalPlatformError.secureStorage
        }
        return try Self.decoder.decode(PersonalPlatformSession.self, from: data)
    }

    public func save(_ session: PersonalPlatformSession) throws {
        let data = try Self.encoder.encode(session)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertion = identity
            insertion.merge(attributes) { _, replacement in replacement }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
                throw PersonalPlatformError.secureStorage
            }
        } else if updateStatus != errSecSuccess {
            throw PersonalPlatformError.secureStorage
        }
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PersonalPlatformError.secureStorage
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
