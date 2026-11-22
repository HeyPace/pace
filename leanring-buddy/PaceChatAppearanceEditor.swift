import SwiftUI

@MainActor
struct PaceChatAppearanceEditor: View {
    @ObservedObject private var appearanceStore: PaceChatAppearanceStore
    @State private var draft: PaceChatAppearance
    @Environment(\.dismiss) private var dismiss

    init(appearanceStore: PaceChatAppearanceStore = .shared) {
        self.appearanceStore = appearanceStore
        _draft = State(initialValue: appearanceStore.appearance)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat appearance").font(.system(size: 19, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
            }
            .padding(22)
            Divider().overlay(DS.Colors.borderSubtle)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    Text("Preview text and spacing here. Done applies your settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Picker("Font", selection: $draft.fontFamily) {
                        ForEach(PaceChatAppearance.FontFamily.allCases, id: \.self) { family in
                            Text(family.title).tag(family)
                        }
                    }
                    .pointerCursor()
                    slider("Text size", value: $draft.bodyTextSize, range: 13...20, suffix: "pt")
                    slider("Extra line spacing", value: $draft.additionalLineSpacing, range: 0...8, suffix: "pt")
                    slider("Content padding", value: $draft.contentPadding, range: 16...36, suffix: "pt")
                    Picker("Quick chat width", selection: $draft.panelWidth) {
                        ForEach(PaceChatAppearance.PanelWidth.allCases, id: \.self) { width in
                            Text("\(width.rawValue) pt").tag(width)
                        }
                    }
                    .pointerCursor()
                    Text("Width applies to anchored quick chat. The notch keeps its hardware size.")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Picker("Control accent", selection: $draft.controlAccent) {
                        ForEach(PaceChatAppearance.ControlAccent.allCases, id: \.self) { accent in
                            Text(accent.title).tag(accent)
                        }
                    }
                    .pointerCursor()
                    Text("Recording, privacy, approval and result colors stay consistent.")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .padding(22)
            }
            Divider().overlay(DS.Colors.borderSubtle)
            HStack {
                Button("Reset") { draft = .default }
                    .pointerCursor()
                    .help("Reset this preview. Done saves it.")
                Spacer()
                Button("Done") {
                    appearanceStore.apply(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .pointerCursor()
            }
            .padding(22)
        }
        .font(.system(size: 12))
        .foregroundStyle(DS.Colors.textPrimary)
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
        .frame(width: 540, height: 650)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How can Pace help?")
                .font(draft.font(size: 15, weight: .medium))
                .lineSpacing(draft.lineSpacing(existing: 4))
            Text("Speak or type a request. Your conversation stays together as Pace works.")
                .font(draft.font(size: 14))
                .lineSpacing(draft.lineSpacing(existing: 5))
                .foregroundStyle(DS.Colors.textPrimary.opacity(0.9))
            HStack {
                Text("Message Pace…")
                    .font(draft.font(size: 14))
                    .foregroundStyle(DS.Colors.textSecondary)
                Spacer()
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(draft.controlAccent == .blue ? DS.Colors.textPrimary : draft.controlForeground)
                    .frame(width: 28, height: 28)
                    .background(
                        draft.controlColor(existing: DS.Colors.surfaceRaised), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(12)
            .overlay {
                RoundedRectangle(cornerRadius: 8).stroke(
                    draft.controlColor(existing: DS.Colors.textSecondary).opacity(0.45), lineWidth: 0.7)
            }
        }
        .padding(draft.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(DS.Colors.borderSubtle, lineWidth: 1)
        }
        .accessibilityLabel("Chat appearance preview")
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String)
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)").foregroundStyle(DS.Colors.textSecondary)
            }
            Slider(value: value, in: range, step: 1)
                .accessibilityLabel(title)
                .pointerCursor()
        }
    }
}
