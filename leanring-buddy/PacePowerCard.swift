import Foundation

nonisolated struct PacePowerCard: Equatable, Sendable {
    struct Choice: Equatable, Sendable {
        let label: String
        let feedback: String
        let correct: Bool?
    }
    struct Page: Equatable, Sendable {
        let title: String
        let body: String
        let choices: [Choice]
        var transcript: String {
            title + "\n" + body + (choices.isEmpty ? "" : "\n" + choices.map(\.label).joined(separator: " · "))
        }
    }
    let title: String
    let pages: [Page]
    let illustration: PaceGeneratedSVG?

    private init(title: String, pages: [Page], illustration: PaceGeneratedSVG?) {
        self.title = title
        self.pages = pages
        self.illustration = illustration
    }

    static func parse(_ source: String) -> Self? {
        guard source.utf8.count <= 48 * 1024, let data = source.data(using: .utf8),
            let root = try? JSONDecoder().decode([String: PaceMCPJSONValue].self, from: data),
            Set(root.keys).isSubset(of: ["title", "pages", "svg"]),
            let title = text(root["title"], maximum: 100),
            case .array(let pageValues)? = root["pages"], (1...12).contains(pageValues.count)
        else { return nil }
        var pages: [Page] = []
        for value in pageValues {
            guard case .object(let page) = value, Set(page.keys).isSubset(of: ["title", "body", "choices"]),
                let title = text(page["title"], maximum: 100), let body = text(page["body"], maximum: 2000)
            else { return nil }
            var choices: [Choice] = []
            if let value = page["choices"] {
                guard case .array(let values) = value, values.count <= 4 else { return nil }
                for value in values {
                    guard case .object(let choice) = value,
                        Set(choice.keys).isSubset(of: ["label", "feedback", "correct"]),
                        let label = text(choice["label"], maximum: 80),
                        let feedback = text(choice["feedback"], maximum: 500)
                    else { return nil }
                    let correct: Bool?
                    if let value = choice["correct"] {
                        guard case .bool(let flag) = value else { return nil }
                        correct = flag
                    } else {
                        correct = nil
                    }
                    guard !choices.contains(where: { $0.label == label }) else { return nil }
                    choices.append(Choice(label: label, feedback: feedback, correct: correct))
                }
            }
            pages.append(Page(title: title, body: body, choices: choices))
        }
        let illustration: PaceGeneratedSVG?
        if let value = root["svg"] {
            guard case .string(let source) = value, let svg = PaceGeneratedSVG.parse(source) else { return nil }
            illustration = svg
        } else {
            illustration = nil
        }
        return Self(title: title, pages: pages, illustration: illustration)
    }

    private static func text(_ value: PaceMCPJSONValue?, maximum: Int) -> String? {
        guard case .string(let text)? = value, text.count <= maximum,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }
}

/// UI state is local to one validated presentation, never executable generated code.
nonisolated enum PacePowerCardInteraction: Equatable {
    case select(pageIndex: Int, choiceIndex: Int)
    case navigate(pageIndex: Int)
}

nonisolated struct PacePowerCardSession {
    let card: PacePowerCard
    private(set) var pageIndex = 0
    private(set) var selections: [Int: Int] = [:]
    var page: PacePowerCard.Page { card.pages[pageIndex] }
    var selectedChoice: Int? { selections[pageIndex] }

    mutating func select(_ choiceIndex: Int, authorize: (PacePowerCardInteraction) -> Bool) {
        guard page.choices.indices.contains(choiceIndex), selectedChoice != choiceIndex else { return }
        guard authorize(.select(pageIndex: pageIndex, choiceIndex: choiceIndex)) else { return }
        selections[pageIndex] = choiceIndex
    }

    mutating func move(by offset: Int, authorize: (PacePowerCardInteraction) -> Bool) {
        guard offset == -1 || offset == 1 else { return }
        let destination = pageIndex + offset
        guard card.pages.indices.contains(destination),
            authorize(.navigate(pageIndex: destination))
        else { return }
        pageIndex = destination
    }
}
