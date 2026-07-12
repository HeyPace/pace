//
//  PaceAXTargeter.swift
//  leanring-buddy
//
//  Hybrid click targeting via the macOS Accessibility (AX) API.
//
//  Given a CG global point (the same coordinate space CGEvent uses),
//  asks the system for the deepest interactive AX element at that
//  point. If we land on something pressable (button, link, menu item,
//  checkbox, etc.), we trigger it via `AXUIElementPerformAction` with
//  `kAXPressAction`. This is more robust than CGEvent clicks because:
//
//    - Layout shifts of a few pixels don't break the click — AX
//      resolves the element by hit-testing, not pixel coordinates.
//    - Action lands semantically (the app sees the same event as
//      keyboard activation, not a synthesised mouse-down).
//    - Many UIs reject CGEvent clicks that arrive too fast; AX
//      bypasses that throttling.
//
//  When AX can't find an element or pressing fails, the caller falls
//  back to the existing CGEvent path in `PaceActionExecutor`.
//

import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class PaceAXTargeter {
    /// Roles we know how to press. Anything outside this set falls
    /// through to a CGEvent click — for instance plain `AXStaticText`
    /// elements that aren't actually interactive.
    private static let pressableRoles: Set<String> = [
        "AXButton",
        "AXLink",
        "AXMenuItem",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXTabGroup", // tab containers — children handle actual press
        "AXTab",
        "AXDisclosureTriangle",
        "AXStepper"
    ]

    private let systemWideElement: AXUIElement = AXUIElementCreateSystemWide()

    /// Attempts to click the AX element at `globalCGPoint`. Returns true
    /// when AX found a pressable element and the press action succeeded.
    /// Returns false on any miss — the caller should fall back to
    /// CGEvent so the click still lands.
    func tryClickViaAccessibility(atGlobalCGPoint globalCGPoint: CGPoint) -> Bool {
        guard let elementAtPosition = copyElementAtGlobalPoint(globalCGPoint) else {
            return false
        }

        let resolvedElement = climbToPressableAncestor(startingAt: elementAtPosition)
            ?? elementAtPosition

        guard let roleString = stringAttribute(kAXRoleAttribute, of: resolvedElement) else {
            return false
        }

        guard Self.pressableRoles.contains(roleString) else {
            // Found an element but it's not in our pressable taxonomy
            // (e.g. AXImage, AXStaticText). Fall through to CGEvent.
            print("🪟 AX targeting: element at (\(Int(globalCGPoint.x)), \(Int(globalCGPoint.y))) has non-pressable role \(roleString) — falling back to CGEvent")
            return false
        }

        let pressResult = AXUIElementPerformAction(resolvedElement, kAXPressAction as CFString)
        if pressResult == .success {
            let elementLabel = stringAttribute(kAXTitleAttribute, of: resolvedElement)
                ?? stringAttribute(kAXDescriptionAttribute, of: resolvedElement)
                ?? "<no label>"
            print("🪟 AX targeting: pressed \(roleString) \"\(elementLabel)\"")
            return true
        }

        print("🪟 AX targeting: press action failed (\(pressResult.rawValue)) on \(roleString) — falling back to CGEvent")
        return false
    }

    // MARK: - Helpers

    private func copyElementAtGlobalPoint(_ globalCGPoint: CGPoint) -> AXUIElement? {
        var elementAtPosition: AXUIElement?
        let copyResult = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(globalCGPoint.x),
            Float(globalCGPoint.y),
            &elementAtPosition
        )
        guard copyResult == .success else {
            // Common error: permission missing. We log because the user
            // may not have realised the AX prompt didn't get granted.
            if copyResult == .apiDisabled || copyResult == .cannotComplete {
                print("⚠️ AX targeting: AXUIElementCopyElementAtPosition failed (\(copyResult.rawValue)) — accessibility permission missing or revoked")
            }
            return nil
        }
        return elementAtPosition
    }

    /// Many UIs nest a pressable button under a non-pressable container
    /// (e.g. `AXImage` inside an `AXButton`). Walk up the AX parent
    /// chain a few hops looking for something we can press.
    private func climbToPressableAncestor(startingAt startElement: AXUIElement) -> AXUIElement? {
        var currentElement: AXUIElement = startElement
        // Climb at most 4 hops — beyond that we're almost certainly in
        // the window/app shell which isn't usefully pressable.
        for _ in 0..<4 {
            if let roleString = stringAttribute(kAXRoleAttribute, of: currentElement),
               Self.pressableRoles.contains(roleString) {
                return currentElement
            }

            var parentValue: CFTypeRef?
            let parentResult = AXUIElementCopyAttributeValue(
                currentElement,
                kAXParentAttribute as CFString,
                &parentValue
            )
            guard parentResult == .success, let parentObject = parentValue else {
                return nil
            }
            // We have to bridge the CFTypeRef back to AXUIElement
            // through a CFTypeID check so we don't trip force-cast
            // crashes on weird AX trees.
            if CFGetTypeID(parentObject) == AXUIElementGetTypeID() {
                currentElement = parentObject as! AXUIElement
            } else {
                return nil
            }
        }
        return nil
    }

    private func stringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(
            element,
            attributeName as CFString,
            &attributeValue
        )
        guard copyResult == .success else { return nil }
        return attributeValue as? String
    }
}
