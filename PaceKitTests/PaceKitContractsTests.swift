import Foundation
import PaceKit
import Testing

@Suite("PaceKit contracts")
struct PaceKitContractsTests {
    @Test("Cloud-backed Kith snapshots round-trip without flattening the domain")
    func kithSnapshotRoundTrip() throws {
        let person = PaceKithPersonAttention(
            id: UUID(),
            name: "Rahul",
            circle: "close",
            closeness: 5,
            lastInteractionAt: Date(timeIntervalSince1970: 1_700_000_000),
            daysSinceInteraction: 12,
            attentionAfterDays: 7,
            attentionRequired: true
        )
        let snapshot = PaceApplicationSnapshot(
            source: PaceSourceReference(
                application: .kith,
                generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                connectorState: .current,
                provenance: "Kith domain records in Personal Platform D1",
                deepLink: try #require(URL(string: "kith://people/\(person.id.uuidString)"))
            ),
            status: "Rahul needs attention",
            alerts: ["Last interaction was 12 days ago"],
            suggestedAction: PaceAvailableAction(
                name: "kith.record_interaction",
                title: "Record an interaction with Rahul",
                arguments: ["person_name": .string("Rahul")]
            ),
            domain: .kith(PaceKithSummary(people: [person], attentionRequired: [person]))
        )

        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(PaceApplicationSnapshot.self, from: encoded) == snapshot)
    }

    @Test("Action results retain provenance and source-defined undo")
    func actionResultRoundTrip() throws {
        let actionID = UUID()
        let result = PaceActionResult(
            actionID: actionID,
            sourceApplication: .calorie,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .succeeded,
            message: "Logged breakfast",
            undoInformation: PaceUndoInformation(
                action: PaceAvailableAction(
                    name: "life.undo",
                    title: "Remove logged breakfast",
                    arguments: ["action_id": .string(actionID.uuidString)]
                )
            )
        )

        let encoded = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(PaceActionResult.self, from: encoded) == result)
    }
}
