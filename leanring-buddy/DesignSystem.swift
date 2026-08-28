//
//  DesignSystem.swift
//  leanring-buddy
//
//  Centralized design system using a blue accent palette on dark surfaces,
//  with a unified button style system. All colors, button styles, and
//  interaction states are defined here as the single source of truth.
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Colors.accent`, etc.
enum DS {

    // MARK: - Color Tokens
    //
    // Pace's actual UI is minimal — menu-bar panel, overlay cursor, and
    // a few status pills. Only the tokens used by current views are kept
    // here. The earlier full Tailwind palette + Material Design state-
    // layer scaffolding was over-built for what shipped; periphery's
    // dead-code scan confirmed none of the extra tokens were referenced.

    enum Colors {

        // ── Backgrounds ──────────────────────────────────────────────

        /// The deepest background — pure black. Sets a premium,
        /// contrast-forward dark surface that lets the accent blue
        /// and any white-opacity-elevated cards pop without the
        /// "off-black gray" muddiness lighter values introduce.
        static let background = Color(hex: "#080A0D")

        /// The graphite desk surface used by full-window native experiences.
        static let surface = Color(hex: "#101318")

        /// Raised operating surface for controls and selected navigation.
        static let surfaceRaised = Color(hex: "#171B22")

        /// Recessed surface for transcript and diagnostic wells.
        static let surfaceInset = Color(hex: "#080A0D")

        /// Card / panel surface that sits one elevation above the
        /// base background. Pure-black main surface means cards need
        /// their OWN tint (rather than the previous "opacity over
        /// off-black gray" trick) so they read as elevated. Very dark

        // ── Borders ──────────────────────────────────────────────────

        /// Subtle border — used for card outlines, dividers, input
        /// field borders. Slightly cooler now so dividers stay
        /// visible against pure black without feeling industrial.
        static let borderSubtle = Color(hex: "#2A3039")

        // ── Text ─────────────────────────────────────────────────────

        /// Primary text — main body text, titles, headings.
        static let textPrimary = Color(hex: "#F1F0EC")

        /// Secondary text — descriptions, hints, muted labels.
        static let textSecondary = Color(hex: "#A7AFBA")

        /// Tertiary text — very muted, used for section labels, timestamps, disabled text.
        static let textTertiary = Color(hex: "#8B9590")

        /// Text on the accent fill (the Blue-600 keystone). White → ~5.1:1
        /// contrast on #2563eb (WCAG AA).
        static let textOnAccent: Color = .white

        // ── Accent ───────────────────────────────────────────────────

        /// The single accent token — solid blue used for primary CTAs,
        /// hover backgrounds, and the overlay cursor's gradient stops.
        static let accent = Color(hex: "#2563eb")

        /// Pace's local signal. The deeper blue keeps white control labels at
        /// accessible contrast while preserving the product's single accent.
        static let localSignal = accent

        /// Explicit disclosure for a planner boundary that leaves the Mac.
        static let offDeviceSignal = Color(hex: "#FFB347")

        // ── Semantic ─────────────────────────────────────────────────

        /// Success — checkmarks, granted permission status indicators.
        static let success = Color(hex: "#34D399")      // Tailwind Emerald 400

        /// Warning — caution messages, manual verification failure explanations.
        static let warning = Color(hex: "#FFB224")      // Radix Amber 9

        static let failure = Color(hex: "#FF6B6B")
        static let blocked = Color(hex: "#F59E5B")

        // ── Overlay Cursor ───────────────────────────────────────────

        /// The blue cursor/bubble color used in OverlayWindow.
        /// Kept distinct from the accent since it serves a different purpose
        /// (screen overlay vs in-app UI).
        static let overlayCursorBlue = Color(hex: "#3380FF")

        // ── Tuition-mode annotation palette ──────────────────────────
        //
        // Bright, distinct hues that read clearly over any underlying
        // screen content. Used by `PaceAnnotationShapeView` in
        // OverlayWindow to color rects/ellipses/lines/arrows/polygons
        // drawn by the planner's `draw_annotation` tool. Default is
        // `annotationRed` — same as the planner's default color.
        static let annotationRed    = Color(red: 0.95, green: 0.30, blue: 0.30)
        static let annotationBlue   = Color(red: 0.30, green: 0.55, blue: 0.95)
        static let annotationGreen  = Color(red: 0.30, green: 0.75, blue: 0.45)
        static let annotationYellow = Color(red: 0.95, green: 0.80, blue: 0.30)
        static let annotationOrange = Color(red: 0.95, green: 0.55, blue: 0.25)
    }

    enum Radius {
        static let control: CGFloat = 10
        static let surface: CGFloat = 14
        static let window: CGFloat = 20
    }

    /// Semantic roles keep Pace readable when the system text size changes.
    /// Display moments stay rare; working surfaces use native text styles.
    enum Typography {
        static let display = Font.system(.largeTitle, design: .default, weight: .medium)
        static let windowTitle = Font.system(.title, design: .default, weight: .semibold)
        static let sceneTitle = Font.system(.title, design: .default, weight: .medium)
        static let sectionTitle = Font.system(.title3, design: .default, weight: .semibold)
        static let headline = Font.system(.headline, design: .default, weight: .semibold)
        static let body = Font.system(.body, design: .default, weight: .regular)
        static let bodyStrong = Font.system(.body, design: .default, weight: .semibold)
        static let callout = Font.system(.callout, design: .default, weight: .regular)
        static let calloutStrong = Font.system(.callout, design: .default, weight: .semibold)
        static let caption = Font.system(.caption, design: .default, weight: .regular)
        static let captionStrong = Font.system(.caption, design: .default, weight: .semibold)
        static let metadata = Font.system(.caption2, design: .monospaced, weight: .semibold)
    }

    enum Motion {
        static let micro = 0.16
        static let stateChange = 0.28
        static let sceneReveal = 0.64
        static let handoff = 1.0
    }
}

// MARK: - Convenience View Extensions

extension View {
    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }

    /// Gives plain SwiftUI controls the same restrained hover signal while
    /// preserving the system's keyboard focus treatment.
    func paceControlHoverHighlight(
        cornerRadius: CGFloat,
        isEnabled: Bool = true
    ) -> some View {
        modifier(
            PaceControlHoverHighlight(
                cornerRadius: cornerRadius,
                isEnabled: isEnabled
            )
        )
    }
}

private struct PaceControlHoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    let isEnabled: Bool

    @State private var isHovered = false
    @FocusState private var isKeyboardFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .focusable(isEnabled)
            .focused($isKeyboardFocused)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        DS.Colors.localSignal.opacity(
                            isEnabled && (isHovered || isKeyboardFocused) ? 0.72 : 0
                        ),
                        lineWidth: isKeyboardFocused ? 1.6 : 1
                    )
                    .allowsHitTesting(false)
            }
            .scaleEffect(reduceMotion || !isEnabled ? 1 : (isHovered ? 1.015 : 1))
            .animation(
                reduceMotion ? nil : .easeOut(duration: DS.Motion.micro),
                value: isHovered
            )
            .onHover { hovering in
                isHovered = isEnabled && hovering
            }
    }
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Color Utilities

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

}
