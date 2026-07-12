//
//  PaceScreenContextMergerTests.swift
//  leanring-buddyTests
//
//  Verifies the VLM-elements + OCR-boxes merge logic. This is where
//  the 2B VLM's "I see a button" gets fused with Apple Vision's
//  "the button says 'Save Draft'" — the text fidelity that lets us
//  ship a 2B model without losing readable content to small-text
//  hallucination. Bbox-overlap math is the core invariant.
//

import Testing
@testable import Pace

struct PaceScreenContextMergerTests {

    // MARK: - Empty inputs

    @Test func emptyOCRReturnsVLMAnalysisUnchanged() async throws {
        let vlmAnalysis = LocalVLMScreenAnalysis(
            elements: [
                LocalVLMScreenElement(label: "Submit", role: "button", bbox: [10, 10, 100, 30], text: "Submit")
            ],
            description: "a form"
        )
        let enrichedAnalysis = PaceScreenContextMerger.enrich(
            vlmAnalysis: vlmAnalysis,
            with: []
        )
        #expect(enrichedAnalysis.elements.count == 1)
        #expect(enrichedAnalysis.elements[0].text == "Submit")
        #expect(enrichedAnalysis.description == "a form")
    }

    @Test func emptyVLMWithOCRBoxesAppendsAllAsOrphans() async throws {
        let vlmAnalysis = LocalVLMScreenAnalysis(elements: [], description: "blank")
        let ocrBoxes = [
            RecognizedTextBox(text: "Hello", pixelBoundingBox: [10, 10, 80, 20]),
            RecognizedTextBox(text: "World", pixelBoundingBox: [10, 40, 80, 20])
        ]
        let enrichedAnalysis = PaceScreenContextMerger.enrich(
            vlmAnalysis: vlmAnalysis,
            with: ocrBoxes
        )
        #expect(enrichedAnalysis.elements.count == 2)
        #expect(enrichedAnalysis.elements.allSatisfy { $0.role == "static_text" })
        #expect(enrichedAnalysis.elements.contains { $0.text == "Hello" })
        #expect(enrichedAnalysis.elements.contains { $0.text == "World" })
    }

    // MARK: - Overlap-based replacement

    @Test func ocrFullyInsideVLMElementReplacesItsText() async throws {
        // VLM saw a button-shaped thing at (10,10) 100x30. OCR
        // confirms the literal text inside is "Save Draft" — the
        // merge should swap the element's `text` from the VLM's guess
        // to the verbatim OCR text.
        let vlmAnalysis = LocalVLMScreenAnalysis(
            elements: [
                LocalVLMScreenElement(label: "submit button", role: "button", bbox: [10, 10, 100, 30], text: "Submi")
            ],
            description: "a form with a button"
        )
        let ocrBoxes = [
            RecognizedTextBox(text: "Save Draft", pixelBoundingBox: [20, 15, 60, 20])
        ]
        let enrichedAnalysis = PaceScreenContextMerger.enrich(
            vlmAnalysis: vlmAnalysis,
            with: ocrBoxes
        )
        #expect(enrichedAnalysis.elements.count == 1)
        #expect(enrichedAnalysis.elements[0].text == "Save Draft")
        #expect(enrichedAnalysis.elements[0].label == "submit button")
        #expect(enrichedAnalysis.elements[0].role == "button")
    }

    @Test func multipleOCRBoxesInsideOneElementJoinedInReadingOrder() async throws {
        // VLM saw a wide container at (0,0) 200x80. OCR found two
        // text lines inside. They should join top-to-bottom.
        let vlmAnalysis = LocalVLMScreenAnalysis(
            elements: [
                LocalVLMScreenElement(label: "card", role: "container", bbox: [0, 0, 200, 80], text: "")
            ],
            description: ""
        )
        let ocrBoxes = [
            // Bottom line (y=40) submitted first to verify the merger
            // re-orders, not relies on input order.
            RecognizedTextBox(text: "world", pixelBoundingBox: [10, 40, 60, 20]),
            RecognizedTextBox(text: "hello", pixelBoundingBox: [10, 10, 60, 20])
        ]
        let enrichedAnalysis = PaceScreenContextMerger.enrich(
            vlmAnalysis: vlmAnalysis,
            with: ocrBoxes
        )
        #expect(enrichedAnalysis.elements.count == 1)
        #expect(enrichedAnalysis.elements[0].text == "hello world")
    }

    @Test func ocrBoxOutsideAllElementsBecomesOrphanStaticText() async throws {
        let vlmAnalysis = LocalVLMScreenAnalysis(
            elements: [
                LocalVLMScreenElement(label: "header", role: "container", bbox: [0, 0, 100, 50], text: "")
            ],
            description: ""
        )
        let ocrBoxes = [
            // (500, 500) — far outside the header.
            RecognizedTextBox(text: "footer text", pixelBoundingBox: [500, 500, 100, 20])
        ]
        let enrichedAnalysis = PaceScreenContextMerger.enrich(
            vlmAnalysis: vlmAnalysis,
            with: ocrBoxes
        )
        // The original VLM element + one orphan static_text.
        #expect(enrichedAnalysis.elements.count == 2)
        let orphans = enrichedAnalysis.elements.filter { $0.role == "static_text" }
        #expect(orphans.count == 1)
        #expect(orphans.first?.text == "footer text")
    }

    @Test func ocrBoxOverlappingLessThanHalfDoesNotMerge() async throws {
        // VLM element at (50, 50) 60x30. OCR box at (40, 50) 60x30 —
        // only half the OCR box is inside the element. The merger's
        // threshold is >50%, so this should NOT replace the element's
        // text. It instead becomes an orphan (since it's not >50%
        // inside any element).
        let vlmAnalysis = LocalVLMScreenAnalysis(
            elements: [
                LocalVLMScreenElement(label: "button", role: "button", bbox: [50, 50, 60, 30], text: "Click")
            ],
            description: ""
        )
        let ocrBoxes = [
            RecognizedTextBox(text: "Outside", pixelBoundingBox: [10, 50, 60, 30])
        ]
        let enrichedAnalysis = PaceScreenContextMerger.enrich(
            vlmAnalysis: vlmAnalysis,
            with: ocrBoxes
        )
        // The button should still say "Click" — OCR text didn't merge.
        let button = enrichedAnalysis.elements.first { $0.role == "button" }
        #expect(button?.text == "Click")
    }

    // MARK: - Edge cases

    @Test func vlmElementWithEmptyBboxIsLeftAlone() async throws {
        let vlmAnalysis = LocalVLMScreenAnalysis(
            elements: [
                LocalVLMScreenElement(label: "icon", role: "image", bbox: [], text: "logo")
            ],
            description: ""
        )
        let ocrBoxes = [
            RecognizedTextBox(text: "footer", pixelBoundingBox: [10, 10, 80, 20])
        ]
        let enrichedAnalysis = PaceScreenContextMerger.enrich(
            vlmAnalysis: vlmAnalysis,
            with: ocrBoxes
        )
        // Bbox-less element keeps its label/text intact.
        let icon = enrichedAnalysis.elements.first { $0.role == "image" }
        #expect(icon?.text == "logo")
    }

    @Test func orphanOCRListIsCappedAtThirty() async throws {
        // Stress test: 60 distinct OCR boxes, none overlapping any
        // VLM element. The cap keeps the prompt size bounded.
        let vlmAnalysis = LocalVLMScreenAnalysis(elements: [], description: "")
        let ocrBoxes: [RecognizedTextBox] = (0..<60).map { index in
            RecognizedTextBox(
                text: "fragment \(index)",
                pixelBoundingBox: [10, 10 + index * 25, 80, 20]
            )
        }
        let enrichedAnalysis = PaceScreenContextMerger.enrich(
            vlmAnalysis: vlmAnalysis,
            with: ocrBoxes
        )
        #expect(enrichedAnalysis.elements.count == 30)
    }
}
