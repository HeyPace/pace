import Foundation
import Testing

@testable import Pace

struct PacePersonalControlPlaneTests {
    @Test
    func crossApplicationAnswerCombinesCurrentCalorieAndKithSources() {
        let answer = PacePersonalCrossApplicationReasoner.answer(
            question: "What should I do next today?",
            snapshots: currentSnapshots()
        )

        #expect(answer.sources == [.calorie, .kith])
        #expect(answer.text.contains("45 g below"))
        #expect(answer.text.contains("Contact Rahul"))
        #expect(answer.text.contains("Protein oats"))
        #expect(answer.limitations.isEmpty)
    }

    @Test
    func crossApplicationAnswerDoesNotInferUnavailableKith() {
        var snapshots = currentSnapshots()
        snapshots[.kith] = kithSnapshot(state: .stale)

        let answer = PacePersonalCrossApplicationReasoner.answer(
            question: "What should I do next today?",
            snapshots: snapshots
        )

        #expect(answer.sources == [.calorie])
        #expect(answer.text.contains("only have current data from Calorie"))
        #expect(answer.limitations == ["Kith was unavailable, so Pace did not infer its state."])
    }

    @Test
    func demonstrationCommandRoutesOneTypedActionPerDomain() throws {
        let parsed = try #require(
            PacePersonalCommandParser.parse(
                "Record that I spoke to Rahul and log my usual breakfast.",
                snapshots: currentSnapshots()
            )
        )

        #expect(parsed.actions.map(\.application) == [.calorie, .kith])
        #expect(parsed.actions.map(\.action.name) == ["calorie.log_food", "kith.record_interaction"])
    }

    private func currentSnapshots() -> [PacePersonalApplication: PaceApplicationSnapshot] {
        [
            .calorie: calorieSnapshot(state: .current),
            .kith: kithSnapshot(state: .current),
        ]
    }

    private func calorieSnapshot(state: PaceConnectorState) -> PaceApplicationSnapshot {
        PaceApplicationSnapshot(
            source: PaceSourceReference(
                application: .calorie,
                generatedAt: Date(),
                connectorState: state,
                provenance: "test",
                deepLink: URL(string: "https://calorie.example/app")!
            ),
            status: "45 g protein remaining",
            alerts: [],
            suggestedAction: nil,
            domain: .calorie(
                PaceCalorieSummary(
                    date: "2026-08-20",
                    calories: 600,
                    proteinGrams: 55,
                    proteinTargetLowGrams: 100,
                    proteinTargetHighGrams: 140,
                    waterMillilitres: 900,
                    waterTargetMillilitres: 2_500,
                    suggestedFoodID: "food-1",
                    suggestedFoodName: "Protein oats",
                    suggestedFoodAmount: 1
                )
            )
        )
    }

    private func kithSnapshot(state: PaceConnectorState) -> PaceApplicationSnapshot {
        let person = PaceKithPersonAttention(
            id: UUID(),
            name: "Rahul",
            circle: "close",
            closeness: 5,
            lastInteractionAt: Date().addingTimeInterval(-10 * 86_400),
            daysSinceInteraction: 10,
            attentionAfterDays: 7,
            attentionRequired: true
        )
        return PaceApplicationSnapshot(
            source: PaceSourceReference(
                application: .kith,
                generatedAt: Date(),
                connectorState: state,
                provenance: "test",
                deepLink: URL(string: "kith://people")!
            ),
            status: "One follow-up due",
            alerts: [],
            suggestedAction: nil,
            domain: .kith(PaceKithSummary(people: [person], attentionRequired: [person]))
        )
    }
}
