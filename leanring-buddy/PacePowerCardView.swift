import AppKit
import SwiftUI

struct PacePowerCardView: View {
    let card: PacePowerCard
    let illustrationView: NSView?
    let authorizeInteraction: (PacePowerCardInteraction) -> Bool
    let dismiss: () -> Void
    @State private var session: PacePowerCardSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        card: PacePowerCard, illustrationView: NSView?,
        authorizeInteraction: @escaping (PacePowerCardInteraction) -> Bool,
        dismiss: @escaping () -> Void
    ) {
        self.card = card
        self.illustrationView = illustrationView
        self.authorizeInteraction = authorizeInteraction
        self.dismiss = dismiss
        _session = State(initialValue: PacePowerCardSession(card: card))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack").foregroundStyle(DS.Colors.textSecondary).accessibilityHidden(true)
                Text(card.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 8)
                Button(action: dismiss) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(CardButtonStyle()).accessibilityLabel("Close Power card")
            }.padding(18)
            Divider()
            if let illustrationView {
                CardIllustrationView(view: illustrationView)
                    .frame(maxWidth: .infinity).frame(height: 180).allowsHitTesting(false)
                    .padding(.top, 14)
            }
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Step \(session.pageIndex + 1) of \(card.pages.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DS.Colors.textTertiary)
                        Text(session.page.title).font(.system(size: 23, weight: .semibold)).fixedSize(
                            horizontal: false, vertical: true)
                        Text(session.page.body).font(.system(size: 14)).lineSpacing(5)
                            .foregroundStyle(.white.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
                        ForEach(session.page.choices.indices, id: \.self) { index in
                            let choice = session.page.choices[index]
                            Button {
                                session.select(index, authorize: authorizeInteraction)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(
                                        systemName: session.selectedChoice == index ? "checkmark.circle.fill" : "circle"
                                    )
                                    .foregroundStyle(
                                        session.selectedChoice == index ? Color.white : Color.white.opacity(0.4))
                                    Text(choice.label).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(CardButtonStyle(selected: session.selectedChoice == index))
                            .accessibilityLabel("Answer: " + choice.label)
                            .accessibilityValue(session.selectedChoice == index ? "Selected" : "")
                        }
                        if let selected = session.selectedChoice {
                            let choice = session.page.choices[selected]
                            HStack(alignment: .top, spacing: 9) {
                                Image(
                                    systemName: choice.correct == true
                                        ? "checkmark.circle"
                                        : (choice.correct == false ? "arrow.trianglehead.clockwise" : "lightbulb"))
                                Text(choice.feedback).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 13)).lineSpacing(4).padding(13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityElement(children: .combine).accessibilityLabel("Feedback: " + choice.feedback)
                            .id("power-card-feedback")
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.selectedChoice, initial: true) { _, selectedChoice in
                    guard selectedChoice != nil else { return }
                    if reduceMotion {
                        scrollProxy.scrollTo("power-card-feedback", anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.16)) {
                            scrollProxy.scrollTo("power-card-feedback", anchor: .bottom)
                        }
                    }
                }
                .id(session.pageIndex)
            }
            Divider()
            HStack {
                Button {
                    session.move(by: -1, authorize: authorizeInteraction)
                } label: {
                    Label("Back", systemImage: "chevron.left").padding(.horizontal, 12).padding(.vertical, 9)
                }.buttonStyle(CardButtonStyle()).disabled(session.pageIndex == 0).accessibilityLabel(
                    "Previous card step")
                Spacer()
                Text("\(session.pageIndex + 1) / \(card.pages.count)")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(DS.Colors.textTertiary)
                Spacer()
                if session.pageIndex + 1 < card.pages.count {
                    Button {
                        session.move(by: 1, authorize: authorizeInteraction)
                    } label: {
                        Label("Next", systemImage: "chevron.right").padding(.horizontal, 12).padding(.vertical, 9)
                    }.buttonStyle(CardButtonStyle(selected: true)).accessibilityLabel("Next card step")
                } else {
                    Button(action: dismiss) { Text("Close").padding(.horizontal, 12).padding(.vertical, 9) }
                        .buttonStyle(CardButtonStyle(selected: true)).accessibilityLabel("Close lesson")
                }
            }.padding(16)
        }
        .foregroundStyle(.white)
        .background(DS.Colors.background)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: session.selectedChoice)
        .colorScheme(.dark)
    }
}

private struct CardButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        CardButtonSurface(configuration: configuration, selected: selected)
    }
    private struct CardButtonSurface: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .background(
                    .white.opacity(configuration.isPressed ? 0.2 : (hovering || selected ? 0.12 : 0.04)),
                    in: RoundedRectangle(cornerRadius: DS.Radius.control)
                )
                .opacity(isEnabled ? 1 : 0.3)
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
                .onHover { hovering = $0 }
                .overlay { if isEnabled { PointerCursorView().allowsHitTesting(false) } }
        }
    }
}

private struct CardIllustrationView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
