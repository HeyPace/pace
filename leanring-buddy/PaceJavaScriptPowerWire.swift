import Foundation

@objc(PaceJavaScriptPowerServiceProtocol)
protocol PaceJavaScriptPowerServiceProtocol {
    nonisolated func evaluate(_ request: Data, withReply reply: @escaping (Data) -> Void)
    nonisolated func cancel(_ runIdentifier: String)
}

nonisolated enum PaceJavaScriptPowerLimits {
    static let serviceIdentifier = "com.pace.PowerJavaScriptService"
    static let maximumSourceBytes = 24 * 1024
    static let maximumOutputBytes = 64 * 1024
    static let maximumActions = 50
    static let executionSeconds: Double = 2
}

nonisolated struct PaceJavaScriptPowerRequest: Codable, Sendable {
    let runIdentifier: String
    let source: String
    let localHour: Int
    let weekday: Int
}

nonisolated struct PaceJavaScriptPowerAction: Codable, Sendable {
    let tool: String
    let arguments: [String: String]
}

nonisolated struct PaceJavaScriptPowerResponse: Codable, Sendable {
    let actions: [PaceJavaScriptPowerAction]
    let failure: String?
}
