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

    private enum CodingKeys: String, CodingKey { case source, target, label, from, to }
    init(source: String, target: String, label: String?) {
        self.source = source
        self.target = target
        self.label = label
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func endpoint(_ canonical: CodingKeys, alias: CodingKeys) throws -> String {
            let primary = try values.decodeIfPresent(String.self, forKey: canonical)
            let alternative = try values.decodeIfPresent(String.self, forKey: alias)
            if let primary, let alternative, primary != alternative {
                throw DecodingError.dataCorruptedError(
                    forKey: canonical, in: values, debugDescription: "Conflicting connection endpoints")
            }
            guard let endpoint = primary ?? alternative else {
                throw DecodingError.keyNotFound(
                    canonical, .init(codingPath: decoder.codingPath, debugDescription: "Missing connection endpoint"))
            }
            return endpoint
        }
        self.init(
            source: try endpoint(.source, alias: .from), target: try endpoint(.target, alias: .to),
            label: try values.decodeIfPresent(String.self, forKey: .label))
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(source, forKey: .source)
        try values.encode(target, forKey: .target)
        try values.encodeIfPresent(label, forKey: .label)
    }
}

extension PaceDiagramNode {
    private enum CodingKeys: String, CodingKey {
        case id, label, detail, x, y, width, height, shape, role, subtitle
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            label: try values.decode(String.self, forKey: .label),
            detail: try values.decode(String.self, forKey: .detail),
            x: try values.decodeIfPresent(Double.self, forKey: .x) ?? 0,
            y: try values.decodeIfPresent(Double.self, forKey: .y) ?? 0,
            width: try values.decodeIfPresent(Double.self, forKey: .width) ?? 220,
            height: try values.decodeIfPresent(Double.self, forKey: .height) ?? 130,
            shape: try values.decodeIfPresent(Shape.self, forKey: .shape),
            role: try values.decodeIfPresent(Role.self, forKey: .role),
            subtitle: try values.decodeIfPresent(String.self, forKey: .subtitle)
        )
    }
}

nonisolated struct PaceDiagramDocument: Codable, Equatable, Sendable {
    let title: String
    let summary: String
    let nodes: [PaceDiagramNode]
    let connections: [PaceDiagramConnection]
    var figure: PaceFigureScene? = nil

    static let maximumNodeCount = 12
    static let maximumConnectionCount = 24
    static let canvasWidth: Double = 1000
    static let canvasHeight: Double = 600

    var validationIssue: String? {
        guard Self.validText(title, maximum: 100), Self.validText(summary, maximum: 500) else {
            return "requires a title up to 100 characters and summary up to 500 characters"
        }
        guard (1...Self.maximumNodeCount).contains(nodes.count),
            connections.count <= Self.maximumConnectionCount
        else {
            return "requires one to twelve parts and at most twenty-four connections"
        }
        let identifiers = nodes.map(\.id)
        guard Set(identifiers).count == identifiers.count,
            identifiers.allSatisfy({ identifier in
                !identifier.isEmpty && identifier.count <= 40
                    && identifier.unicodeScalars.allSatisfy {
                        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
                    }
            })
        else { return "requires unique short alphanumeric part IDs" }
        for node in nodes {
            guard Self.validText(node.label, maximum: 80),
                Self.validText(node.detail, maximum: 1200),
                node.subtitle.map({ Self.validText($0, maximum: 100) }) ?? true
            else {
                return "requires bounded labels and a useful explanation for every part"
            }
        }
        if let figure {
            guard connections.isEmpty else {
                return "uses solid geometry rather than flowchart connections for a 3D figure"
            }
            return figure.validationIssue(nodeIDs: Set(identifiers))
        }
        for node in nodes {
            guard [node.x, node.y, node.width, node.height].allSatisfy(\.isFinite),
                node.x >= 0, node.y >= 0, node.width >= 180, node.height >= 100,
                node.width <= 500, node.height <= 300,
                node.x + node.width <= Self.canvasWidth,
                node.y + node.height <= Self.canvasHeight
            else {
                return "requires finite part bounds inside a 1000 by 600 canvas, width 180–500 and height 100–300"
            }
        }
        for (index, node) in nodes.enumerated() {
            for other in nodes.dropFirst(index + 1) {
                if node.x < other.x + other.width && node.x + node.width > other.x
                    && node.y < other.y + other.height && node.y + node.height > other.y
                {
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
                connectionIdentifiers.insert(connection.source + ":" + connection.target).inserted
            else {
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
            encodedArguments.count <= 64_000,
            let document = try? JSONDecoder().decode(Self.self, from: encodedArguments),
            document.validationIssue == nil
        else { return nil }
        return document
    }

    static let selectedPartQuestion =
        "Explain the selected diagram part using the active diagram context. Walk me through what it does and how it connects to the other parts; update the diagram if a closer view would help."

    static func requestsDiagram(_ transcript: String, hasActiveDiagram: Bool) -> Bool {
        let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if hasActiveDiagram && transcript == selectedPartQuestion { return true }
        let explicitLearningForms = [
            #"^(?:please\s+)?(?:explain|teach|help me understand)\s+.+\s+(?:with|using|as)\s+(?:an?\s+)?(?:interactive\s+)?(?:diagram|flowchart|concept map|mind map)[.!?]*$"#,
            #"^(?:please\s+)?(?:draw|show|generate)\s+(?:me\s+)?(?:an?\s+)?(?:interactive\s+)?(?:diagram|flowchart|concept map|mind map)\s+(?:of|about|showing|explaining)\s+.+[.!?]*$"#,
            #"^(?:please\s+)?(?:explain|walk me through|draw|visualize|visualise)\s+(?:this|that)\s+(?:diagram|figure)[.!?]*$"#,
            #"^(?:please\s+)?(?:show|draw|create|generate|make|visualize|visualise)\s+(?:me\s+)?(?:an?\s+)?(?:detailed\s+)?(?:interactive|rotatable|3d|three-dimensional|cutaway)\s+.+[.!?]*$"#,
        ]
        if explicitLearningForms.contains(where: { normalized.range(of: $0, options: .regularExpression) != nil }) {
            return true
        }
        guard hasActiveDiagram else { return false }
        return normalized.range(
            of:
                #"^(?:please\s+)?(?:(?:expand|simplify|explain)\s+(?:this|that)(?:\s+(?:diagram|figure|part))?|show more detail|walk me through (?:this|that)(?:\s+(?:diagram|figure|part))?)[.!?]*$"#,
            options: .regularExpression
        ) != nil
    }

    static func canUseDiagramOnlyFastPath(_ transcript: String, hasActiveDiagram: Bool) -> Bool {
        guard requestsDiagram(transcript, hasActiveDiagram: hasActiveDiagram) else { return false }
        if hasActiveDiagram && transcript == selectedPartQuestion { return true }
        // Ambiguous conjunctions use the full planner so an additional action cannot be lost.
        return transcript.range(of: #"\b(?:and|then|also|plus)\b"#, options: [.regularExpression, .caseInsensitive])
            == nil
    }

    static func requiresScreenContext(_ transcript: String, hasActiveDiagram: Bool) -> Bool {
        let normalized = transcript.lowercased()
        let screenReferences = [
            "on my screen", "on the screen", "this screen", "this page", "this webpage",
            "this code", "this chart", "this image", "this window",
            "looking at", "this article", "this document", "selected text",
        ]
        if screenReferences.contains(where: normalized.contains) { return true }
        return !hasActiveDiagram
            && [
                "this diagram", "that diagram", "this figure", "that figure", "explain this", "explain that",
                "draw this", "draw that", "visualize this", "visualise this", "turn this",
            ].contains(where: normalized.contains)
    }

    static func requestsDismissal(_ transcript: String) -> Bool {
        let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        return [
            "close diagram", "close the diagram", "hide diagram", "hide the diagram", "dismiss diagram",
            "dismiss the diagram", "clear diagram", "clear the diagram",
        ].contains(normalized)
    }

    private static func validText(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= maximum
            && !text.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
            })
    }
}
