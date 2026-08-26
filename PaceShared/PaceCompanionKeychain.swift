import Foundation
import Security

nonisolated struct PaceCompanionStoredCredential: Codable, Equatable, Sendable {
    let remoteIdentifier: String
    let remoteName: String
    let localDeviceIdentifier: String
    let credential: String
}

nonisolated enum PaceCompanionKeychain {
    @discardableResult
    static func store(
        _ storedCredential: PaceCompanionStoredCredential,
        serviceIdentifier: String,
        accountName: String
    ) -> Bool {
        guard let encodedCredential = try? JSONEncoder().encode(storedCredential) else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: accountName,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: encodedCredential] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = encodedCredential
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func load(
        serviceIdentifier: String,
        accountName: String
    ) -> PaceCompanionStoredCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var returnedItem: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &returnedItem) == errSecSuccess,
            let encodedCredential = returnedItem as? Data
        else {
            return nil
        }
        return try? JSONDecoder().decode(PaceCompanionStoredCredential.self, from: encodedCredential)
    }

    @discardableResult
    static func delete(serviceIdentifier: String, accountName: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: accountName,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
