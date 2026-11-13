import Foundation
import SwiftUI

nonisolated struct PaceTeachingArrayIllustration: Codable, Equatable, Sendable {
    struct Row: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case tokens, matrix, metric }
        let nodeID: String
        let kind: Kind
        let values: [String]
        var columns: Int? = nil
        var offset: Int? = nil
    }
    let rows: [Row]
    func validationIssue(nodeIDs: Set<String>) -> String? {
        guard (1...8).contains(rows.count), Set(rows.map(\.nodeID)) == nodeIDs,
              Set(rows.map(\.nodeID)).count == rows.count else {
            return "requires one to eight illustrated arrays, one per semantic part"
        }
        for row in rows {
            guard (1...64).contains(row.values.count),
                  row.values.allSatisfy({ !$0.isEmpty && $0.count <= 24 && !$0.contains("\n") }),
                  row.columns.map({ row.kind == .matrix && (1...12).contains($0) }) ?? true,
                  row.offset.map({ row.kind == .tokens && (0...8).contains($0) && $0 + row.values.count <= 12 }) ?? true,
                  row.kind == .matrix || row.values.count <= 12 else {
                return "requires bounded array cells and matrix dimensions"
            }
        }
        return nil
    }

    func contentHeight(revealedNodeIDs: Set<String>) -> Double {
        let visibleRows = rows.filter { revealedNodeIDs.contains($0.nodeID) }
        let heights = visibleRows.map { row -> Double in
            let gridRows = row.kind == .matrix ? Int(ceil(Double(row.values.count) / Double(row.columns ?? 4))) : 1
            return Double(gridRows) * (row.kind == .matrix ? 24 : 39) + Double(max(0, gridRows - 1)) * 5 + 20
        }
        return max(110, 40 + heights.reduce(0, +) + Double(max(0, visibleRows.count - 1)) * 12)
    }

    static let nextTokenExample = PaceDiagramDocument(
        title: "How a language model learns the next token",
        summary: "Each context predicts the next token. Targets are the same sequence shifted by one position.",
        nodes: [
            .init(id: "sequence", label: "One training sequence", detail: "A training sequence is split into tokens. The example uses whole words for readability; real tokenizers can split words into smaller pieces.", x: 0, y: 0, width: 220, height: 130, shape: nil, role: .input, subtitle: nil),
            .init(id: "context", label: "Context window x", detail: "Choose a block of consecutive tokens as the input. Here the block has four positions. At each position, the model can use only that token and earlier context.", x: 0, y: 0, width: 220, height: 130, shape: nil, role: .input, subtitle: nil),
            .init(id: "target", label: "Shifted target y", detail: "Shift the same block one token to the right to form the targets. The target for each position is exactly the next token, rather than a single label for the entire block.", x: 0, y: 0, width: 220, height: 130, shape: nil, role: .output, subtitle: nil),
            .init(id: "prediction", label: "Model predictions", detail: "The model produces a probability distribution for each position. These displayed words are illustrative top predictions; the loss uses probabilities for the correct target tokens.", x: 0, y: 0, width: 220, height: 130, shape: nil, role: .process, subtitle: nil),
            .init(id: "comparison", label: "Compare with the target", detail: "Cross-entropy penalizes low probability assigned to the correct next token. A wrong top word is a useful visual clue, but loss is not merely the count of mismatched words.", x: 0, y: 0, width: 220, height: 130, shape: nil, role: .process, subtitle: nil),
            .init(id: "update", label: "Update shared weights", detail: "Backpropagation computes how the loss changes with the model weights. The optimizer adjusts those shared weights. Repeating this across many batches improves next-token prediction.", x: 0, y: 0, width: 220, height: 130, shape: nil, role: .output, subtitle: nil)
        ], connections: [], illustration: .init(rows: [
            .init(nodeID: "sequence", kind: .tokens, values: ["the", "cat", "sat", "on", "the", "mat"]),
            .init(nodeID: "context", kind: .tokens, values: ["the", "cat", "sat", "on"]),
            .init(nodeID: "target", kind: .tokens, values: ["cat", "sat", "on", "the"], offset: 1),
            .init(nodeID: "prediction", kind: .tokens, values: ["cat", "slept", "on", "a"]),
            .init(nodeID: "comparison", kind: .metric, values: ["cat → cat", "slept → sat", "on → on", "a → the"]),
            .init(nodeID: "update", kind: .matrix, values: ["+.02", "−.01", "+.03", "−.02", "−.04", "+.01", "+.02", "−.01", "+.01", "−.03", "+.01", "+.02"], columns: 6)
        ]), lesson: .init(steps: [
            .init(id: "sequence", title: "Start with tokens", narration: "Start with a short token sequence. These whole words are a readable teaching example. Actual model tokens may be smaller than a word.", revealedNodeIDs: ["sequence"], focusNodeID: "sequence"),
            .init(id: "context", title: "Choose the context", narration: "Take four consecutive tokens as the input block x. Each position is asked to predict what follows it, using only the context available so far.", revealedNodeIDs: ["sequence", "context"], focusNodeID: "context"),
            .init(id: "target", title: "Shift the target by one", narration: "The target block y starts one token later. The cat sat on becomes cat sat on the. Input and target have the same length, but their positions are shifted by one.", revealedNodeIDs: ["sequence", "context", "target"], focusNodeID: "target"),
            .init(id: "prediction", title: "Predict at every position", narration: "The model predicts a probability distribution at every position. Here are illustrative top words. Two agree with the target and two need improvement.", revealedNodeIDs: ["context", "target", "prediction"], focusNodeID: "prediction"),
            .init(id: "comparison", title: "Measure prediction loss", narration: "Compare each prediction with its true next token. Cross-entropy uses the probability assigned to the correct target, not just whether the top word matches.", revealedNodeIDs: ["target", "prediction", "comparison"], focusNodeID: "comparison"),
            .init(id: "update", title: "Adjust the shared model", narration: "Backpropagation traces that loss into the weights. The optimizer makes a small update. These numbers are illustrative weight changes, not measured model output.", revealedNodeIDs: ["comparison", "update"], focusNodeID: "update")
        ]))
}

struct PaceTeachingArrayView: View {
    @ObservedObject var controller: PaceDiagramOverlayController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleRows, id: \.nodeID) { row in
                        if let node = controller.document?.nodes.first(where: { $0.id == row.nodeID }) {
                            rowView(row, node: node, width: geometry.size.width)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.black, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12)))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: controller.lessonStepIndex)
        }
    }

    private var visibleRows: [PaceTeachingArrayIllustration.Row] {
        let identifiers = Set(controller.visibleNodes.map(\.id))
        return (controller.document?.illustration?.rows ?? []).filter { identifiers.contains($0.nodeID) }
    }

    private func rowView(_ row: PaceTeachingArrayIllustration.Row, node: PaceDiagramNode, width: CGFloat) -> some View {
        let isFocused = controller.selectedNodeID == row.nodeID
        let columns = row.kind == .matrix ? row.columns ?? 4 : row.values.count
        let tokenExtent = max(1, (controller.document?.illustration?.rows ?? [])
            .filter { $0.kind == .tokens }.map { $0.values.count + ($0.offset ?? 0) }.max() ?? 1)
        let tokenWidth = max(25, (width - min(150, width * 0.23) - 95) / CGFloat(tokenExtent) - 5)
        return Button { controller.selectNode(id: row.nodeID) } label: {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.kind == .matrix ? "WEIGHT UPDATE" : node.role?.rawValue.uppercased() ?? "ARRAY")
                        .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.4)
                        .foregroundStyle(.white.opacity(0.42))
                    Text(node.label).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                }
                .frame(width: min(150, width * 0.23), alignment: .leading)
                LazyVGrid(columns: Array(repeating: GridItem(row.kind == .tokens ? .fixed(tokenWidth) : .flexible(), spacing: 5), count: columns), spacing: 5) {
                    ForEach(Array(row.values.enumerated()), id: \.offset) { index, value in
                        VStack(spacing: 3) {
                            Text(value).font(.system(size: row.kind == .matrix ? 12 : 14, weight: .medium, design: .monospaced))
                                .lineLimit(1).minimumScaleFactor(0.65)
                            if row.kind == .tokens {
                                Text("\(index)").font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
                            }
                        }
                        .foregroundStyle(isFocused ? Color(hex: "#B6D5FF") : .white.opacity(0.85))
                        .frame(maxWidth: .infinity, minHeight: row.kind == .matrix ? 24 : 39)
                        .background(.white.opacity(isFocused ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(isFocused ? 0.24 : 0.08)))
                    }
                }
                .frame(width: row.kind == .tokens ? CGFloat(row.values.count) * tokenWidth + CGFloat(row.values.count - 1) * 5 : nil, alignment: .leading)
                .padding(.leading, row.kind == .tokens ? CGFloat(row.offset ?? 0) * (tokenWidth + 5) : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(.white.opacity(isFocused ? 0.025 : 0), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(node.detail)
        .paceControlHoverHighlight(cornerRadius: 12)
        .accessibilityLabel("\(node.label). \(row.values.joined(separator: ", "))")
        .accessibilityIdentifier("pace.lesson.array.\(row.nodeID)")
    }
}
