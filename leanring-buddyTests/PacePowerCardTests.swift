import Foundation
import Testing

@testable import Pace

@MainActor @Suite(.serialized)
struct PacePowerCardTests {
    private let definition = #"{"title":"Japanese practice","pages":[{"title":"A greeting","body":"What does ありがとう mean?","choices":[{"label":"Thank you","feedback":"Correct. Arigatou means thank you.","correct":true},{"label":"Good night","feedback":"Good night is おやすみ. Try again.","correct":false}]},{"title":"Use it","body":"Say ありがとう when someone helps you."}]}"#

    private func source(_ definition: String, options: String = "") -> String {
        "pace.presentCard(" + definition + options + ");"
    }
    private func program(_ source: String) -> PaceProgramDefinition {
        .init(schemaVersion: 2, identifier: "japanese-practice", name: "Japanese practice",
              description: "A greeting quiz", category: "custom", invocationPhrases: ["practice a greeting"],
              requiredPreferences: [], nodes: [.javascript(source: source)])
    }

    @Test func validatesWholeCardWithoutAcceptingExecutableOrMixedContent() throws {
        let card = try #require(PacePowerCard.parse(definition))
        #expect(card.pages.count == 2)
        #expect(card.pages[0].choices[1].correct == false)
        #expect(card.pages[0].transcript.contains("Thank you · Good night"))
        let invalid = [
            definition.replacingOccurrences(of: "\"pages\":", with: "\"onClick\":\"shell\",\"pages\":"),
            definition.replacingOccurrences(of: "\"correct\":true", with: "\"correct\":\"true\""),
            definition.replacingOccurrences(of: "\"body\":", with: "\"tool\":\"open_app\",\"body\":"),
            definition.replacingOccurrences(of: "\"feedback\":", with: "\"url\":\"file:///tmp/private\",\"feedback\":"),
            definition.replacingOccurrences(of: "Good night\",\"feedback", with: "Thank you\",\"feedback"),
            #"{"title":"Empty","pages":[]}"#,
            #"{"title":"Active SVG","pages":[{"title":"One","body":"Text"}],"svg":"<svg xmlns='http://www.w3.org/2000/svg'><script/></svg>"}"#,
        ]
        for value in invalid { #expect(PacePowerCard.parse(value) == nil) }
        let arguments: [String: PaceMCPJSONValue] = ["card": .string(definition), "durationSeconds": .number(120)]
        #expect(PaceMediaPresentationRequest.parse(arguments: arguments)?.card == card)
        for mixed in ["assetID", "svg", "motion"] {
            #expect(PaceMediaPresentationRequest.parse(arguments: arguments.merging([mixed: .string("bad")]) { _, value in value }) == nil)
        }
        #expect(PaceMediaPresentationRequest.parse(arguments: ["card": .string(definition), "durationSeconds": .number(301)]) == nil)
        #expect(PaceMediaPresentationRequest.parse(arguments: ["assetID": .string("hello"), "durationSeconds": .number(120)]) == nil)
    }

    @Test func actualIsolatedWorkerCompilesCardAndRejectsInvalidWholePlan() async throws {
        let context = PaceProgramContext(weekday: 3, localHour: 10, frontmostApplicationBundleIdentifier: nil)
        let outcome = try await PaceJavaScriptPowerRuntime.compile(program(source(definition)), context: context)
        guard case .executionPlan(let plan) = outcome,
              case .presentMedia(let request) = plan.flattenedActions.first else { Issue.record("Card did not reach typed executor"); return }
        #expect(request.card == PacePowerCard.parse(definition))
        #expect(request.durationSeconds == 120)
        let belowBudget = "pace.presentCard({title:'Budget', pages:[], extra:'あ'.repeat(15000)});"
        #expect(try await PaceJavaScriptPowerRun().evaluate(source: belowBudget, context: context).count == 1)
        let oversizedJapanese = "pace.presentCard({title:'Too large', pages:[], extra:'あ'.repeat(17000)});"
        do {
            _ = try await PaceJavaScriptPowerRun().evaluate(source: oversizedJapanese, context: context)
            Issue.record("Worker accepted a card exceeding the UTF-8 byte budget")
        } catch PaceJavaScriptPowerError.invalid { }
        catch { Issue.record("Expected SDK budget rejection, got \(error)") }
        for invalid in [source(definition, options: ", {durationSeconds:301}"), source("{title:'Bad',pages:[],onClick:'shell'}")] {
            do {
                _ = try await PaceJavaScriptPowerRuntime.compile(program("pace.speak('must not run');" + invalid), context: context)
                Issue.record("Invalid card permitted a partial executable plan")
            } catch { }
        }
    }

    @Test func localChoicesAndNavigationRequireAuthorizationAndPreserveSelections() throws {
        var session = PacePowerCardSession(card: try #require(PacePowerCard.parse(definition)))
        var receipts: [PacePowerCardInteraction] = []
        let authorize: (PacePowerCardInteraction) -> Bool = { interaction in receipts.append(interaction); return true }
        session.select(0, authorize: { _ in false })
        #expect(session.selectedChoice == nil)
        session.select(1, authorize: authorize)
        #expect(session.selectedChoice == 1)
        session.select(1, authorize: authorize)
        #expect(receipts.count == 1)
        session.move(by: 1, authorize: { _ in false })
        #expect(session.pageIndex == 0)
        session.move(by: 1, authorize: authorize)
        #expect(session.pageIndex == 1)
        session.move(by: 1, authorize: authorize)
        #expect(receipts.count == 2)
        session.move(by: -1, authorize: authorize)
        #expect(session.selectedChoice == 1)
        session.select(20, authorize: authorize)
        #expect(receipts.count == 3)
    }

    @Test func dismissedReplacedAndUnauthorizedCardsCannotExecuteStaleInteractions() async throws {
        let request = PaceMediaPresentationRequest(card: try #require(PacePowerCard.parse(definition)), durationSeconds: 120)
        let controller = PaceMediaOverlayController(showsWindows: false)
        var authorized = true
        var interactions = 0
        var dismissals = 0
        let present = { await controller.presentCard(request, mayPresent: { authorized }, authorizeInteraction: { _ in
            guard authorized else { return false }; interactions += 1; return true
        }, onDismiss: { _ in dismissals += 1 }) }
        _ = await present()
        let firstGeneration = controller.presentationGeneration
        #expect(controller.handleCardInteraction(ifGenerationMatches: firstGeneration, interaction: .select(pageIndex: 0, choiceIndex: 0)))
        _ = await present()
        #expect(!controller.handleCardInteraction(ifGenerationMatches: firstGeneration, interaction: .select(pageIndex: 0, choiceIndex: 0)))
        authorized = false
        #expect(!controller.handleCardInteraction(ifGenerationMatches: controller.presentationGeneration, interaction: .select(pageIndex: 0, choiceIndex: 0)))
        #expect(!controller.isVisible)
        #expect(interactions == 1)
        #expect(dismissals == 1)
    }

    @Test func managerPersistsDisplayedContentAndChoicesAndRechecksPowerDisablement() async throws {
        let helpers = PacePowerManagerTests()
        let (root, manager, persister, _) = try helpers.fixture()
        defer { manager.cancelActiveTurnTasks(); try? FileManager.default.removeItem(at: root) }
        let author = PacePowerManagerTests.Author()
        author.response = try #require(String(data: JSONEncoder().encode(program(source(definition))), encoding: .utf8))
        manager.reusableWorkAuthoringPlannerOverride = author
        helpers.begin("Add a Power for Japanese practice", manager: manager)
        await manager.handlePowerCommand(.add("Japanese practice"), transcript: "Add a Power for Japanese practice")
        await manager.currentResponseTask?.value
        helpers.begin("run power Japanese practice", manager: manager)
        await manager.handlePowerCommand(.run("Japanese practice"), transcript: "run power Japanese practice")
        await manager.currentResponseTask?.value
        #expect(manager.mediaOverlayController.isVisible)
        let generation = manager.mediaOverlayController.presentationGeneration
        #expect(manager.mediaOverlayController.handleCardInteraction(ifGenerationMatches: generation,
            interaction: .select(pageIndex: 0, choiceIndex: 0)))
        #expect(persister.events.values.contains(where: { $0.origin == .progress && $0.text.contains("Selected “Thank you”") }))
        #expect(persister.events.values.contains(where: { $0.role == .pace && $0.text == "Correct. Arigatou means thank you." }))
        let priorUserCount = persister.events.values.filter { $0.role == .user }.count
        for _ in 0..<3 {
            #expect(manager.mediaOverlayController.handleCardInteraction(ifGenerationMatches: generation, interaction: .navigate(pageIndex: 1)))
            #expect(manager.mediaOverlayController.handleCardInteraction(ifGenerationMatches: generation, interaction: .navigate(pageIndex: 0)))
        }
        #expect(persister.events.values.filter { $0.role == .user }.count == priorUserCount)
        #expect(persister.events.values.filter { $0.text == "Use it\nSay ありがとう when someone helps you." }.count == 1)
        let beforeRepeatedChoiceCount = persister.events.count
        for _ in 0..<3 {
            #expect(manager.mediaOverlayController.handleCardInteraction(ifGenerationMatches: generation, interaction: .select(pageIndex: 0, choiceIndex: 1)))
            #expect(manager.mediaOverlayController.handleCardInteraction(ifGenerationMatches: generation, interaction: .select(pageIndex: 0, choiceIndex: 0)))
        }
        #expect(persister.events.count == beforeRepeatedChoiceCount + 2)
        let discovery = await manager.discoverAutomationCatalog()
        let power = try manager.managedPowerStore.resolve("Japanese practice", catalog: discovery.catalog)
        try manager.managedPowerStore.setEnabled(false, power: power)
        #expect(!manager.mediaOverlayController.handleCardInteraction(ifGenerationMatches: generation, interaction: .navigate(pageIndex: 1)))
        #expect(!manager.mediaOverlayController.isVisible)
    }
}
