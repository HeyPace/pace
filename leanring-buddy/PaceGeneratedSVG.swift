import Foundation

nonisolated struct PaceGeneratedSVG: Equatable, Sendable {
    static let maximumBytes = 32 * 1024
    let markup: String

    private init(markup: String) { self.markup = markup }

    static func parse(_ source: String) -> Self? {
        guard !source.isEmpty, source.utf8.count <= maximumBytes,
              !source.uppercased().contains("<!DOCTYPE"), !source.uppercased().contains("<!ENTITY") else { return nil }
        let validator = PaceSVGXMLValidator()
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = validator
        guard parser.parse(), validator.isValid, validator.depth == 0, validator.rootSeen, validator.markup.utf8.count <= maximumBytes else { return nil }
        return Self(markup: validator.markup)
    }
}

private nonisolated final class PaceSVGXMLValidator: NSObject, XMLParserDelegate {
    private static let namespace = "http://www.w3.org/2000/svg"
    private static let elements: Set<String> = [
        "svg", "g", "defs", "title", "desc", "style", "circle", "ellipse", "rect", "line", "polyline", "polygon", "path", "text", "tspan",
        "linearGradient", "radialGradient", "stop", "clipPath", "mask",
    ]
    private static let attributes: Set<String> = [
        "id", "class", "style", "viewBox", "width", "height", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "d", "points",
        "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-dasharray",
        "stroke-dashoffset", "opacity", "transform", "transform-origin", "preserveAspectRatio", "offset", "stop-color", "stop-opacity",
        "gradientUnits", "gradientTransform", "spreadMethod", "fx", "fy", "fr", "clip-path", "clip-rule", "clipPathUnits", "mask", "maskUnits",
        "maskContentUnits", "dx", "dy", "type",
        "flood-color", "flood-opacity", "operator", "k1", "k2", "k3", "k4", "font-size", "font-family", "font-weight", "text-anchor",
        "dominant-baseline", "letter-spacing", "role", "aria-label", "href",
    ]
    private(set) var isValid = true
    private(set) var depth = 0
    private(set) var rootSeen = false
    private(set) var markup = ""
    private var styleText = ""
    private var nodes = 0
    private var elements: [String] = []

    private func reject(_ parser: XMLParser) { isValid = false; parser.abortParsing() }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        if !prefix.isEmpty || namespaceURI != Self.namespace { reject(parser) }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String]) {
        nodes += 1
        depth += 1
        guard isValid, elements.last != "style", nodes <= 512, depth <= 24, namespaceURI == Self.namespace,
              Self.elements.contains(elementName), elements.last != "style", qualifiedName == nil || qualifiedName == elementName,
              (rootSeen || elementName == "svg"), !(elementName == "svg" && rootSeen) else { reject(parser); return }
        if depth == 1 {
            guard let viewBox = attributeDict["viewBox"] else { reject(parser); return }
            let values = viewBox.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) }
            guard values.count == 4, values.allSatisfy({ $0.isFinite && abs($0) <= 4096 }),
                  values[2] > 0, values[3] > 0 else { reject(parser); return }
        }
        if elementName == "style" { styleText = "" }
        rootSeen = true
        var serialized = "<" + elementName
        if depth == 1 { serialized += " xmlns=\"" + Self.namespace + "\"" }
        for (name, value) in attributeDict.sorted(by: { $0.key < $1.key }) {
            guard Self.attributes.contains(name), value.utf8.count <= 8192,
                  Self.safeCSS(value, stylesheet: name == "style"), Self.safeDimension(name: name, value: value), name != "href" || Self.localReference(value) else { reject(parser); return }
            if name == "viewBox" {
                let tokens = value.split(whereSeparator: { $0.isWhitespace || $0 == "," })
                let components = tokens.compactMap { Double($0) }
                guard tokens.count == 4, components.count == 4, components.allSatisfy({ $0.isFinite && abs($0) <= 4096 }),
                      components[2] > 0, components[3] > 0 else { reject(parser); return }
            }
            guard Self.safeDimension(name: name, value: value),
                  !["d", "points", "transform", "gradientTransform"].contains(name) || Self.boundedNumbers(value) else { reject(parser); return }
            serialized += " " + name + "=\"" + Self.escape(value) + "\""
        }
        markup += serialized + ">"
        elements.append(elementName)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "style" {
            guard Self.safeCSS(styleText, stylesheet: true) else { reject(parser); return }
            markup += Self.escape(styleText)
        }
        markup += "</" + elementName + ">"
        _ = elements.popLast()
        depth -= 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if elements.last == "style" { styleText += string }
        else { markup += Self.escape(string) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { reject(parser); return }
        self.parser(parser, foundCharacters: string)
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundSkippedEntityName name: String) { reject(parser) }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundElementDeclarationWithName name: String, model: String) { reject(parser) }
    func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String, type: String?, defaultValue: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) { reject(parser) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { reject(parser); return nil }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func safeDimension(name: String, value: String) -> Bool {
        guard ["width", "height", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy", "fr", "dx", "dy", "font-size", "stroke-width"].contains(name) else { return true }
        let number: String
        if value.hasSuffix("px") { number = String(value.dropLast(2)) }
        else if value.hasSuffix("%") { number = String(value.dropLast()) }
        else { number = value }
        return Double(number).map { $0.isFinite && abs($0) <= 4096 } == true
    }

    private static func localReference(_ value: String) -> Bool {
        value.range(of: #"^#[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    private static func boundedNumbers(_ value: String) -> Bool {
        let numbers = try! NSRegularExpression(pattern: #"[-+]?(?:[0-9]*\.)?[0-9]+(?:[eE][-+]?[0-9]+)?"#)
        for match in numbers.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let numberRange = Range(match.range, in: value), let number = Double(value[numberRange]),
                  number.isFinite, abs(number) <= 4096 else { return false }
        }
        return true
    }

    private static func safeCSS(_ value: String, stylesheet: Bool = false) -> Bool {
        let lowercase = value.lowercased()
        guard !value.contains("\\"), !value.contains("<"), !value.contains(">"),
              !lowercase.contains("/*"), !lowercase.contains("expression"), !lowercase.contains("-webkit-") else { return false }
        let transforms = try! NSRegularExpression(pattern: #"(?:translate|scale|rotate|matrix|skew)[a-z0-9]*\s*\(([^)]*)\)"#, options: .caseInsensitive)
        for match in transforms.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let transformRange = Range(match.range(at: 1), in: value), boundedNumbers(String(value[transformRange])) else { return false }
        }
        if stylesheet {
            let properties: Set<String> = ["animation", "animation-name", "animation-duration", "animation-delay", "animation-timing-function", "animation-iteration-count", "animation-direction", "animation-fill-mode", "animation-play-state", "transform", "transform-origin", "transform-box", "opacity", "fill", "fill-opacity", "stroke", "stroke-width", "stroke-opacity", "color"]
            let declarations = try! NSRegularExpression(pattern: #"(?:^|[;{])\s*([A-Za-z-]+)\s*:"#)
            for match in declarations.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                guard let propertyRange = Range(match.range(at: 1), in: value), properties.contains(value[propertyRange].lowercased()) else { return false }
            }
        }
        let atRules = try! NSRegularExpression(pattern: #"@([A-Za-z-]+)"#)
        let cssRange = NSRange(value.startIndex..., in: value)
        for match in atRules.matches(in: value, range: cssRange) {
            guard stylesheet, let nameRange = Range(match.range(at: 1), in: value), value[nameRange] == "keyframes" else { return false }
        }
        let expression = try! NSRegularExpression(pattern: #"url\s*\(([^)]*)\)"#, options: .caseInsensitive)
        let range = NSRange(value.startIndex..., in: value)
        for match in expression.matches(in: value, range: range) {
            guard let referenceRange = Range(match.range(at: 1), in: value) else { return false }
            let reference = String(value[referenceRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard localReference(reference) else { return false }
        }
        if lowercase.contains("url") && expression.numberOfMatches(in: value, range: range) == 0 { return false }
        let withoutKeyframes = lowercase.replacingOccurrences(of: "@keyframes", with: "")
        return !withoutKeyframes.contains("@") && (stylesheet || !lowercase.contains("@"))
    }
}
