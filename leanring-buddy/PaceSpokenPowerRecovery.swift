import Foundation

nonisolated struct PacePendingSpokenPowerClarification: Equatable {
    enum Resolution: Equatable { case selected(PaceManagedPower), cancelled, expired, needsSelection, unrelated }
    let identifier: UUID
    let candidates: [PaceManagedPower]
    let createdAt: Date
    static let lifetime: TimeInterval = 60

    init(candidates: [PaceManagedPower], createdAt: Date = Date()) {
        identifier = UUID()
        self.candidates = Array(candidates.prefix(3))
        self.createdAt = createdAt
    }

    var options: [String] {
        candidates.map { candidate in
            let matchingNames = candidates.filter {
                PaceSpokenPowerRecovery.normalized($0.name) == PaceSpokenPowerRecovery.normalized(candidate.name)
            }
            return "Run " + candidate.name + (matchingNames.count > 1 ? " [" + candidate.identifier + "]" : "")
        }
    }

    func resolve(_ response: String, now: Date) -> Resolution {
        let text = PaceSpokenPowerRecovery.normalized(response)
        if ["cancel", "cancel that", "never mind", "nevermind", "no", "stop"].contains(text) { return .cancelled }
        let affirmative = ["yes", "yes please", "yes run it", "go ahead", "yeah", "yep", "correct", "do it", "run it", "that one"].contains(text)
        let ordinalIndex = [["first", "first one", "one", "1"], ["second", "second one", "two", "2"], ["third", "third one", "three", "3"]]
            .firstIndex { $0.contains(text) }
        var selectedIndex: Int?
        var requiresSpecificChoice = false
        if affirmative {
            if candidates.count == 1 { selectedIndex = 0 }
            requiresSpecificChoice = true
        } else if let ordinalIndex {
            if candidates.indices.contains(ordinalIndex) { selectedIndex = ordinalIndex }
            requiresSpecificChoice = true
        } else if let exactOptionIndex = options.firstIndex(of: response.trimmingCharacters(in: .whitespacesAndNewlines)) {
            selectedIndex = exactOptionIndex
        } else {
            let matchingOptions = options.indices.filter { PaceSpokenPowerRecovery.normalized(options[$0]) == text }
            let target: String
            if text.hasPrefix("run power ") { target = String(text.dropFirst(10)) }
            else if text.hasPrefix("run the ") { target = String(text.dropFirst(8)) }
            else if text.hasPrefix("run ") { target = String(text.dropFirst(4)) }
            else { target = text }
            let matchingNames = candidates.indices.filter { PaceSpokenPowerRecovery.normalized(candidates[$0].name) == target }
            let matchingIndices = matchingOptions.isEmpty ? matchingNames : matchingOptions
            if matchingIndices.count == 1 { selectedIndex = matchingIndices[0] }
            requiresSpecificChoice = matchingIndices.count > 1
        }
        guard selectedIndex != nil || requiresSpecificChoice else { return .unrelated }
        guard now.timeIntervalSince(createdAt) >= 0, now.timeIntervalSince(createdAt) < Self.lifetime else { return .expired }
        guard let selectedIndex else { return .needsSelection }
        return .selected(candidates[selectedIndex])
    }

}

nonisolated enum PaceSpokenPowerRecovery {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func candidates(for transcript: String, powers: [PaceManagedPower], explicitRunTarget: String? = nil) -> [PaceManagedPower] {
        guard transcript.count <= 160, explicitRunTarget != nil || !transcript.contains("?") else { return [] }
        var words = normalized(explicitRunTarget ?? transcript).split(separator: " ").map(String.init)
        if explicitRunTarget == nil {
            guard ["run", "power"].contains(words.first ?? ""), words.count >= 2 else { return [] }
            words.removeFirst()
            if words.first == "power" { words.removeFirst() }
            guard !["nap", "supply", "saving", "management", "consumption", "settings", "mode", "options"].contains(words.first ?? ""),
                  !words.contains(where: { ["terminal", "browser", "click", "open", "type", "command", "script", "tests", "test", "automation", "shortcut", "flow", "skill", "workflow"].contains($0) }) else { return [] }
        }
        words.removeAll { ["and", "the", "a", "please"].contains($0) }
        guard !words.isEmpty, words.count <= 8 else { return [] }
        let savedPowers = powers.filter { $0.isManagedUserArtifact && $0.reference != nil && $0.name.count <= 100 }
        var ranked: [(power: PaceManagedPower, score: Double)] = []
        for power in savedPowers.prefix(64) {
            let nameWords = normalized(power.name).split(separator: " ").map(String.init)
            let candidateScore = score(words, name: nameWords)
            if candidateScore >= 0.6 {
                ranked.append((power: power, score: candidateScore))
            }
        }
        ranked.sort { first, second in
            first.score == second.score ? first.power.identifier < second.power.identifier : first.score > second.score
        }
        guard let best = ranked.first else { return [] }
        if ranked.count == 1 || best.score - ranked[1].score >= 0.1 { return [best.power] }
        return ranked.prefix(3).filter { best.score - $0.score < 0.1 }.map { $0.power }
    }

    private static func score(_ words: [String], name: [String]) -> Double {
        guard !name.isEmpty, name.count <= 5 else { return 0 }
        if words.count < name.count {
            return similarity(words.joined(), name.joined())
        }
        return (0...(words.count - name.count)).map { start in
            zip(words[start..<(start + name.count)], name).map { spoken, saved in
                guard spoken.first == saved.first else { return 0.0 }
                return max(similarity(spoken, saved), similarity(phonetic(spoken), phonetic(saved)))
            }.reduce(0, +) / Double(name.count)
        }.max() ?? 0
    }

    private static func similarity(_ first: String, _ second: String) -> Double {
        let firstCharacters = Array(first), secondCharacters = Array(second)
        guard !firstCharacters.isEmpty, !secondCharacters.isEmpty else { return 0 }
        var previous = Array(0...secondCharacters.count)
        for (firstIndex, firstCharacter) in firstCharacters.enumerated() {
            var current = [firstIndex + 1]
            for (secondIndex, secondCharacter) in secondCharacters.enumerated() {
                current.append(min(current[secondIndex] + 1, previous[secondIndex + 1] + 1,
                    previous[secondIndex] + (firstCharacter == secondCharacter ? 0 : 1)))
            }
            previous = current
        }
        return 1 - Double(previous[secondCharacters.count]) / Double(max(firstCharacters.count, secondCharacters.count))
    }

    private static func phonetic(_ word: String) -> String {
        guard let first = word.first else { return "" }
        let groups = ["bfpv", "cgjkqsxz", "dt", "l", "mn", "r"]
        func code(_ character: Character) -> String? { groups.firstIndex { $0.contains(character) }.map { String($0 + 1) } }
        var result = String(first), previous = code(first)
        for character in word.dropFirst() {
            let next = code(character)
            if let next, next != previous { result += next }
            previous = next
            if result.count == 4 { break }
        }
        return String((result + "000").prefix(4))
    }
}
