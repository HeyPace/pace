import Foundation

nonisolated struct PaceDiagramNode: Codable, Equatable, Identifiable, Sendable {
    enum Shape: String, Codable, Sendable { case rectangle, ellipse, capsule }
    enum Role: String, Codable, Sendable { case input, process, output, concept }

    let id: String
    let label: String
    let detail: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let shape: Shape?
    let role: Role?
    let subtitle: String?
}

nonisolated struct PaceDiagramConnection: Codable, Equatable, Sendable {
    let source: String
    let target: String
    let label: String?
}

nonisolated struct PaceDiagramDocument: Codable, Equatable, Sendable {
    let title: String
    let summary: String
    let nodes: [PaceDiagramNode]
    let connections: [PaceDiagramConnection]

    static let maximumNodeCount = 12
    static let maximumConnectionCount = 24
    static let canvasWidth: Double = 1000
    static let canvasHeight: Double = 600

    var validationIssue: String? {
        guard Self.validText(title, maximum: 100), Self.validText(summary, maximum: 500) else {
            return "requires a title up to 100 characters and summary up to 500 characters"
        }
        guard (1...Self.maximumNodeCount).contains(nodes.count),
              connections.count <= Self.maximumConnectionCount else {
            return "requires one to twelve parts and at most twenty-four connections"
        }
        let identifiers = nodes.map(\.id)
        guard Set(identifiers).count == identifiers.count,
              identifiers.allSatisfy({ identifier in
                  !identifier.isEmpty && identifier.count <= 40
                    && identifier.unicodeScalars.allSatisfy {
                        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
                    }
              }) else { return "requires unique short alphanumeric part IDs" }
        for node in nodes {
            guard Self.validText(node.label, maximum: 80),
                  Self.validText(node.detail, maximum: 1200),
                  node.subtitle.map({ Self.validText($0, maximum: 100) }) ?? true else {
                return "requires bounded labels and a useful explanation for every part"
            }
            guard [node.x, node.y, node.width, node.height].allSatisfy(\.isFinite),
                  node.x >= 0, node.y >= 0, node.width >= 180, node.height >= 100,
                  node.width <= 500, node.height <= 300,
                  node.x + node.width <= Self.canvasWidth,
                  node.y + node.height <= Self.canvasHeight else {
                return "requires finite part bounds inside a 1000 by 600 canvas, width 180–500 and height 100–300"
            }
        }
        for (index, node) in nodes.enumerated() {
            for other in nodes.dropFirst(index + 1) {
                if node.x < other.x + other.width && node.x + node.width > other.x
                    && node.y < other.y + other.height && node.y + node.height > other.y {
                    return "requires nonoverlapping parts so every part remains visible and clickable"
                }
            }
        }
        let knownIdentifiers = Set(identifiers)
        var connectionIdentifiers = Set<String>()
        for connection in connections {
            guard knownIdentifiers.contains(connection.source), knownIdentifiers.contains(connection.target),
                  connection.source != connection.target,
                  connection.label.map({ Self.validText($0, maximum: 80) }) ?? true,
                  connectionIdentifiers.insert(connection.source + ":" + connection.target).inserted else {
                return "requires unique connections between existing, distinct parts with short labels"
            }
        }
        return nil
    }

    static func parse(arguments: [String: PaceMCPJSONValue]) -> PaceDiagramDocument? {
        let diagramArguments: [String: PaceMCPJSONValue]
        if case .object(let documentArguments) = arguments["document"] {
            diagramArguments = documentArguments
        } else {
            diagramArguments = arguments
        }
        guard let encodedArguments = try? JSONEncoder().encode(diagramArguments),
              encodedArguments.count <= 40_000,
              let document = try? JSONDecoder().decode(Self.self, from: encodedArguments),
              document.validationIssue == nil else { return nil }
        return document
    }

    static func requestsDiagram(_ transcript: String, hasActiveDiagram: Bool) -> Bool {
        let normalized = transcript.lowercased()
        if ["diagram", "flowchart", "visualize", "visualise", "concept map", "mind map", "draw me", "sketch"].contains(where: normalized.contains) {
            return true
        }
        return hasActiveDiagram && [
            "expand that", "expand this", "simplify", "show more detail", "explain this part",
            "explain that part", "walk me through", "change this", "change that", "add to this"
        ].contains(where: normalized.contains)
    }

    static func requiresScreenContext(_ transcript: String, hasActiveDiagram: Bool) -> Bool {
        let normalized = transcript.lowercased()
        let screenReferences = [
            "on my screen", "on the screen", "this screen", "this page", "this webpage",
            "this code", "this chart", "this image", "this window",
            "looking at", "this article", "this document", "selected text"
        ]
        if screenReferences.contains(where: normalized.contains) { return true }
        return !hasActiveDiagram && [
            "this diagram", "that diagram", "this figure", "that figure", "explain this", "explain that",
            "draw this", "draw that", "visualize this", "visualise this", "turn this"
        ].contains(where: normalized.contains)
    }

    static func requestsDismissal(_ transcript: String) -> Bool {
        let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        return ["close diagram", "close the diagram", "hide diagram", "hide the diagram", "dismiss diagram", "dismiss the diagram", "clear diagram", "clear the diagram"].contains(normalized)
    }

    private static func validText(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= maximum
            && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" })
    }
}
