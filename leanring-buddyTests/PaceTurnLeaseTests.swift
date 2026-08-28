import Testing
@testable import Pace

@Suite("Turn lease registry")
struct PaceTurnLeaseTests {
    @Test("Beginning a new turn invalidates the previous lease")
    func beginningNewTurnInvalidatesPreviousLease() {
        var registry = PaceTurnLeaseRegistry()
        let firstTurnLease = registry.beginTurn()
        let secondTurnLease = registry.beginTurn()

        #expect(!registry.isCurrent(firstTurnLease))
        #expect(registry.isCurrent(secondTurnLease))
    }

    @Test("Cancellation invalidates the active lease")
    func cancellationInvalidatesActiveLease() {
        var registry = PaceTurnLeaseRegistry()
        let activeTurnLease = registry.beginTurn()

        registry.invalidateCurrentTurn()

        #expect(!registry.isCurrent(activeTurnLease))
    }
}
