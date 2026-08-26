import CryptoKit
import Foundation

nonisolated struct PaceCompanionTLSMaterial: Equatable, Sendable {
    let preSharedKey: Data
    let identity: Data
}

nonisolated enum PaceCompanionSecurity {
    private static let keyDerivationSalt = Data("PacePad local TLS v1".utf8)

    static func generatePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    static func normalizedPairingCode(_ value: String) -> String? {
        var normalizedDigits = ""
        for character in value {
            if character.isASCII, character.isNumber {
                normalizedDigits.append(character)
            } else if character.isWhitespace || character == "-" {
                continue
            } else {
                return nil
            }
        }
        guard normalizedDigits.count == 6 else { return nil }
        return normalizedDigits
    }

    static func generateCredential() -> String {
        let generatedKey = SymmetricKey(size: .bits256)
        return generatedKey.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    static func pairingTLSMaterial(pairingCode: String) -> PaceCompanionTLSMaterial? {
        guard let normalizedCode = normalizedPairingCode(pairingCode) else { return nil }
        return tlsMaterial(
            secretData: Data(normalizedCode.utf8),
            identity: "pacepad-pairing-v1"
        )
    }

    static func credentialTLSMaterial(
        credential: String,
        deviceIdentifier: String
    ) -> PaceCompanionTLSMaterial? {
        guard let credentialData = Data(base64Encoded: credential),
            credentialData.count == PaceCompanionProtocol.credentialByteCount,
            !deviceIdentifier.isEmpty
        else {
            return nil
        }
        return tlsMaterial(
            secretData: credentialData,
            identity: "pacepad-device-\(deviceIdentifier)"
        )
    }

    static func sessionAuthenticationProof(
        credential: String,
        serverIdentifier: String,
        deviceIdentifier: String,
        sessionIdentifier: String
    ) -> String? {
        guard let credentialData = Data(base64Encoded: credential),
            credentialData.count == PaceCompanionProtocol.credentialByteCount
        else {
            return nil
        }
        let authenticationMessage = Data(
            "\(serverIdentifier)|\(deviceIdentifier)|\(sessionIdentifier)".utf8
        )
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: authenticationMessage,
            using: SymmetricKey(data: credentialData)
        )
        return Data(authenticationCode).base64EncodedString()
    }

    static func validateSessionAuthenticationProof(
        _ proof: String,
        credential: String,
        serverIdentifier: String,
        deviceIdentifier: String,
        sessionIdentifier: String
    ) -> Bool {
        guard
            let expectedProof = sessionAuthenticationProof(
                credential: credential,
                serverIdentifier: serverIdentifier,
                deviceIdentifier: deviceIdentifier,
                sessionIdentifier: sessionIdentifier
            ), let expectedData = Data(base64Encoded: expectedProof),
            let providedData = Data(base64Encoded: proof)
        else {
            return false
        }
        return constantTimeEqual(expectedData, providedData)
    }

    private static func tlsMaterial(
        secretData: Data,
        identity: String
    ) -> PaceCompanionTLSMaterial {
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secretData),
            salt: keyDerivationSalt,
            info: Data(identity.utf8),
            outputByteCount: 32
        )
        let preSharedKey = derivedKey.withUnsafeBytes { Data($0) }
        return PaceCompanionTLSMaterial(
            preSharedKey: preSharedKey,
            identity: Data(identity.utf8)
        )
    }

    private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { accumulatedDifference, bytes in
            accumulatedDifference | (bytes.0 ^ bytes.1)
        } == 0
    }
}
