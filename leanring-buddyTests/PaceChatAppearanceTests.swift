import Foundation
import XCTest
@testable import Pace

final class PaceChatAppearanceTests: XCTestCase {
    func testMissingCorruptAndUnsupportedAppearanceRecoverDefaults() {
        XCTAssertEqual(PaceChatAppearance.restore(from: nil), .default)
        XCTAssertEqual(PaceChatAppearance.restore(from: Data("broken".utf8)), .default)
        XCTAssertEqual(PaceChatAppearance.restore(from: Data(#"{"schemaVersion":2,"bodyTextSize":20}"#.utf8)), .default)
        XCTAssertEqual(PaceChatAppearance.restore(from: Data(#"{"schemaVersion":1,"fontFamily":"remote"}"#.utf8)), .default)
        XCTAssertEqual(PaceChatAppearance.restore(from: Data(#"{"schemaVersion":1,"panelWidth":9000}"#.utf8)), .default)
        XCTAssertEqual(PaceChatAppearance.restore(from: Data(#"{"schemaVersion":1}"#.utf8)), .default)
    }

    func testDecodeClampsFiniteValuesAndPreservesExplicitZeroSpacing() throws {
        let appearance = try JSONDecoder().decode(PaceChatAppearance.self, from: Data(
            #"{"schemaVersion":1,"bodyTextSize":200,"additionalLineSpacing":0,"contentPadding":-100,"panelWidth":680,"controlAccent":"silver","fontFamily":"rounded"}"#.utf8))
        XCTAssertEqual(appearance.bodyTextSize, 20)
        XCTAssertEqual(appearance.additionalLineSpacing, 0)
        XCTAssertEqual(appearance.contentPadding, 16)
        XCTAssertEqual(appearance.panelWidth, .wide)
        XCTAssertEqual(appearance.controlAccent, .silver)
        XCTAssertEqual(appearance.fontFamily, .rounded)
    }

    func testNonfiniteUpdatesRecoverEachScalarAndClampOtherBounds() {
        var appearance = PaceChatAppearance.default
        appearance.bodyTextSize = .nan
        appearance.additionalLineSpacing = .infinity
        appearance.contentPadding = -.infinity
        XCTAssertEqual(appearance.normalized(), .default)
        appearance.bodyTextSize = 0
        appearance.additionalLineSpacing = 100
        appearance.contentPadding = 100
        XCTAssertEqual(appearance.normalized().bodyTextSize, 13)
        XCTAssertEqual(appearance.normalized().additionalLineSpacing, 8)
        XCTAssertEqual(appearance.normalized().contentPadding, 36)
    }

    func testDefaultKeepsExistingRendererSpacingAndWidths() {
        let appearance = PaceChatAppearance.default
        XCTAssertEqual(appearance.anchoredWidth(), 520)
        XCTAssertEqual(appearance.anchoredWidth(existing: 320), 320)
        XCTAssertEqual(appearance.padding(), 20)
        XCTAssertEqual(appearance.padding(existing: 24), 24)
        XCTAssertEqual(appearance.padding(existing: 14), 14)
        XCTAssertEqual(appearance.lineSpacing(existing: 4), 4)
        XCTAssertEqual(appearance.lineSpacing(existing: 5), 5)
        XCTAssertEqual(appearance.lineSpacing(existing: 6), 6)
        XCTAssertEqual(appearance.bodyTextSize, 14)
    }

    @MainActor
    func testDraftResetAndDiscardLeaveSavedAppearanceUntilDone() throws {
        let suiteName = "PaceChatAppearanceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PaceChatAppearanceStore(defaults: defaults)
        var chosenAppearance = PaceChatAppearance.default
        chosenAppearance.fontFamily = .monospace
        chosenAppearance.bodyTextSize = 18
        chosenAppearance.panelWidth = .comfortable
        chosenAppearance.controlAccent = .silver
        store.apply(chosenAppearance)

        var editorDraft = store.appearance
        editorDraft.contentPadding = 36
        XCTAssertEqual(store.appearance, chosenAppearance)
        editorDraft = .default
        XCTAssertEqual(store.appearance, chosenAppearance)
        XCTAssertEqual(PaceChatAppearanceStore(defaults: defaults).appearance, chosenAppearance)

        store.apply(editorDraft)
        XCTAssertEqual(store.appearance, .default)
        XCTAssertEqual(PaceChatAppearanceStore(defaults: defaults).appearance, .default)
    }

    @MainActor
    func testSavingNormalizesBeforePublishingAndPersisting() throws {
        let suiteName = "PaceChatAppearanceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PaceChatAppearanceStore(defaults: defaults)
        var appearance = PaceChatAppearance.default
        appearance.bodyTextSize = .nan
        appearance.additionalLineSpacing = 100
        store.apply(appearance)
        XCTAssertEqual(store.appearance.bodyTextSize, 14)
        XCTAssertEqual(store.appearance.additionalLineSpacing, 8)
        XCTAssertEqual(PaceChatAppearanceStore(defaults: defaults).appearance, store.appearance)
    }

    func testWideAnchoredChatFitsSmallDisplayWithNegativeOrigin() {
        let screenFrame = CGRect(x: -700, y: -100, width: 600, height: 500)
        let placement = PaceConversationPanelPlacement.resolve(
            notchGeometry: nil,
            anchorFrame: CGRect(x: -110, y: 380, width: 22, height: 20),
            screenFrame: screenFrame,
            contentSize: CGSize(width: 680, height: 540))
        guard case .anchored = placement else { return XCTFail("Expected anchored placement") }
        XCTAssertEqual(placement.frame.size, CGSize(width: 584, height: 484))
        XCTAssertTrue(screenFrame.insetBy(dx: 8, dy: 8).contains(placement.frame))
    }

    func testAnchoredAppearanceWidthDoesNotChangePhysicalNotchGeometry() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let housing = CGRect(x: 770, y: 1085, width: 185, height: 32)
        let geometry = PaceLivingNotchGeometry(physicalHousingFrame: housing, presentationFrame: housing)
        let quiet = PaceConversationPanelPlacement.resolve(
            notchGeometry: geometry, anchorFrame: housing, screenFrame: screenFrame,
            contentSize: CGSize(width: 520, height: 540))
        let wide = PaceConversationPanelPlacement.resolve(
            notchGeometry: geometry, anchorFrame: housing, screenFrame: screenFrame,
            contentSize: CGSize(width: 680, height: 540))
        XCTAssertEqual(quiet, wide)
        XCTAssertEqual(wide.frame.width, 520)
        XCTAssertEqual(wide.frame.height, 412)
    }
}
