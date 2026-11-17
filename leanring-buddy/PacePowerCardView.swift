import AppKit
import SwiftUI

struct PacePowerCardView: View {
    let card: PacePowerCard
    let illustrationView: NSView?
    let authorizeInteraction: (PacePowerCardInteraction) -> Bool
    let dismiss: () -> Void
    @State private var session: PacePowerCardSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(card: PacePowerCard, illustrationView: NSView?, authorizeInteraction: @escaping (PacePowerCardInteraction) -> Bool,
         dismiss: @escaping () -> Void) {
        self.card = card
        self.illustrationView = illustrationView
        self.authorizeInteraction = authorizeInteraction
        self.dismiss = dismiss
        _session = State(initialValue: PacePowerCardSession(card: card))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(.white.opacity(0.6))
                Text(card.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 8)
                Button(action: dismiss) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(CardButtonStyle()).accessibilityLabel("Close Power card")
            }.padding(18)
            Divider().overlay(.white.opacity(0.1))
            if let illustrationView {
                CardIllustrationView(view: illustrationView)
                    .frame(maxWidth: .infinity).frame(height: 180).allowsHitTesting(false)
                    .padding(.top, 14)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("STEP \(session.pageIndex + 1) OF \(card.pages.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(session.page.title).font(.system(size: 23, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(session.page.body).font(.system(size: 14)).lineSpacing(5)
                        .foregroundStyle(.white.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
                    ForEach(session.page.choices.indices, id: \.self) { index in
                        let choice = session.page.choices[index]
                        Button {
                            session.select(index, authorize: authorizeInteraction)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: session.selectedChoice == index ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(session.selectedChoice == index ? Color.white : Color.white.opacity(0.4))
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
                            Image(systemName: choice.correct == true ? "checkmark.circle" : (choice.correct == false ? "arrow.trianglehead.clockwise" : "lightbulb"))
                            Text(choice.feedback).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 13)).lineSpacing(4).padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .combine).accessibilityLabel("Feedback: " + choice.feedback)
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }.id(session.pageIndex)
            Divider().overlay(.white.opacity(0.1))
            HStack {
                Button { session.move(by: -1, authorize: authorizeInteraction) } label: {
                    Label("Back", systemImage: "chevron.left").padding(.horizontal, 12).padding(.vertical, 9)
                }.buttonStyle(CardButtonStyle()).disabled(session.pageIndex == 0).accessibilityLabel("Previous card step")
                Spacer()
                Text("\(session.pageIndex + 1) / \(card.pages.count)")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                if session.pageIndex + 1 < card.pages.count {
                    Button { session.move(by: 1, authorize: authorizeInteraction) } label: {
                        Label("Next", systemImage: "chevron.right").padding(.horizontal, 12).padding(.vertical, 9)
                    }.buttonStyle(CardButtonStyle(selected: true)).accessibilityLabel("Next card step")
                } else {
                    Button(action: dismiss) { Text("Close").padding(.horizontal, 12).padding(.vertical, 9) }
                        .buttonStyle(CardButtonStyle(selected: true)).accessibilityLabel("Close lesson")
                }
            }.padding(16)
        }
        .foregroundStyle(.white)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.16), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22))
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
                .background(.white.opacity(configuration.isPressed ? 0.2 : (hovering || selected ? 0.12 : 0.04)),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(selected ? 0.36 : 0.1), lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.3)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onHover { hovering = $0 }
                .overlay { if isEnabled { PointerCursorView().allowsHitTesting(false) } }
        }
    }
}

private struct CardIllustrationView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) { }
}
