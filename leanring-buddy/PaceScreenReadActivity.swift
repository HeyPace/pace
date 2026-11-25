import Combine
import Foundation

@MainActor
final class PaceScreenReadActivity: ObservableObject {
    static let shared = PaceScreenReadActivity()

    @Published private(set) var isReading = false
    private var activeReadIdentifiers: Set<UUID> = []

    func beginReading() -> UUID {
        let readIdentifier = UUID()
        activeReadIdentifiers.insert(readIdentifier)
        if !isReading { isReading = true }
        return readIdentifier
    }

    func endReading(_ readIdentifier: UUID) {
        activeReadIdentifiers.remove(readIdentifier)
        let hasActiveReads = !activeReadIdentifiers.isEmpty
        if isReading != hasActiveReads { isReading = hasActiveReads }
    }

    func whileReading<Result>(_ operation: () async throws -> Result) async rethrows -> Result {
        let readIdentifier = beginReading()
        defer { endReading(readIdentifier) }
        return try await operation()
    }
}
