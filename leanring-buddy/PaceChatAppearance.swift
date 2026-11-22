import Combine
import SwiftUI

nonisolated struct PaceChatAppearance: Codable, Equatable, Sendable {
    enum FontFamily: String, Codable, CaseIterable, Sendable {
        case system, rounded, monospace
        var title: String { rawValue.capitalized }
    }

    enum PanelWidth: Int, Codable, CaseIterable, Sendable {
        case standard = 520
        case comfortable = 600
        case wide = 680
    }

    enum ControlAccent: String, Codable, CaseIterable, Sendable {
        case blue, violet, silver
        var title: String { rawValue.capitalized }
    }

    static let `default` = PaceChatAppearance()
    let schemaVersion: Int = 1
    var fontFamily: FontFamily = .system
    var bodyTextSize: Double = 14
    var additionalLineSpacing: Double = 0
    var contentPadding: Double = 20
    var panelWidth: PanelWidth = .standard
    var controlAccent: ControlAccent = .blue

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, fontFamily, bodyTextSize, additionalLineSpacing
        case contentPadding, panelWidth, controlAccent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container, debugDescription: "Unsupported chat appearance version")
        }
        fontFamily = try container.decodeIfPresent(FontFamily.self, forKey: .fontFamily) ?? .system
        bodyTextSize = try container.decodeIfPresent(Double.self, forKey: .bodyTextSize) ?? 14
        additionalLineSpacing = try container.decodeIfPresent(Double.self, forKey: .additionalLineSpacing) ?? 0
        contentPadding = try container.decodeIfPresent(Double.self, forKey: .contentPadding) ?? 20
        panelWidth = try container.decodeIfPresent(PanelWidth.self, forKey: .panelWidth) ?? .standard
        controlAccent = try container.decodeIfPresent(ControlAccent.self, forKey: .controlAccent) ?? .blue
        bodyTextSize = Self.bounded(bodyTextSize, in: 13...20, fallback: 14)
        additionalLineSpacing = Self.bounded(additionalLineSpacing, in: 0...8, fallback: 0)
        contentPadding = Self.bounded(contentPadding, in: 16...36, fallback: 20)
    }

    func normalized() -> Self {
        var appearance = self
        appearance.bodyTextSize = Self.bounded(bodyTextSize, in: 13...20, fallback: 14)
        appearance.additionalLineSpacing = Self.bounded(additionalLineSpacing, in: 0...8, fallback: 0)
        appearance.contentPadding = Self.bounded(contentPadding, in: 16...36, fallback: 20)
        return appearance
    }

    private static func bounded(_ value: Double, in bounds: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, bounds.lowerBound), bounds.upperBound) : fallback
    }

    static func restore(from data: Data?) -> Self {
        guard let data, let appearance = try? JSONDecoder().decode(Self.self, from: data) else { return .default }
        return appearance
    }

    @MainActor
    func font(size originalSize: CGFloat, weight: Font.Weight = .regular, existing: Font? = nil) -> Font {
        if fontFamily == .system, bodyTextSize == 14, let existing { return existing }
        let design: Font.Design
        switch fontFamily {
        case .system: design = .default
        case .rounded: design = .rounded
        case .monospace: design = .monospaced
        }
        return .system(size: originalSize + CGFloat(bodyTextSize) - 14, weight: weight, design: design)
    }

    func padding(existing: CGFloat = 20) -> CGFloat { existing + CGFloat(contentPadding) - 20 }
    func lineSpacing(existing: CGFloat = 0) -> CGFloat { existing + CGFloat(additionalLineSpacing) }

    func anchoredWidth(existing: CGFloat = 520) -> CGFloat {
        panelWidth == .standard ? existing : CGFloat(panelWidth.rawValue)
    }

    @MainActor
    var controlColor: Color {
        switch controlAccent {
        case .blue: return DS.Colors.accent
        case .violet: return Color(red: 0.46, green: 0.32, blue: 0.80)
        case .silver: return Color(red: 0.80, green: 0.82, blue: 0.86)
        }
    }

    @MainActor
    var controlForeground: Color {
        controlAccent == .silver ? .black : DS.Colors.textOnAccent
    }

    @MainActor
    func controlColor(existing: Color) -> Color {
        controlAccent == .blue ? existing : controlColor
    }
}

@MainActor
final class PaceChatAppearanceStore: ObservableObject {
    static let shared = PaceChatAppearanceStore()
    @Published private(set) var appearance: PaceChatAppearance
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = PaceChatAppearance.restore(
            from: defaults.data(forKey: PaceUserPreferenceKey.chatAppearance.rawValue))
    }

    func apply(_ appearance: PaceChatAppearance) {
        let normalizedAppearance = appearance.normalized()
        guard let data = try? JSONEncoder().encode(normalizedAppearance) else { return }
        defaults.set(data, forKey: PaceUserPreferenceKey.chatAppearance.rawValue)
        self.appearance = normalizedAppearance
    }
}
