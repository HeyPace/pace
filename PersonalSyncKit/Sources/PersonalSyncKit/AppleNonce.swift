import CryptoKit
import Foundation

public enum AppleNonce {
    public static func make() -> String {
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var random = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in characters.randomElement(using: &random)! })
    }

    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
