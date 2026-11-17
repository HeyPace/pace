import CryptoKit
import Darwin
import Foundation

nonisolated enum PacePowerCommand: Equatable {
    case importMedia(String, String)
    case add(String), list, show(String), create(String), update(String, String), setEnabled(String, Bool), remove(String), run(String), dismissMedia
}

nonisolated enum PacePowerCommandParser {
    static func parse(_ transcript: String, isKnownSavedPowerName: (String) -> Bool = { _ in false }) -> PacePowerCommand? {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<2 {
            guard let courtesyPrefix = ["please ", "can you ", "could you "].first(where: { text.lowercased().hasPrefix($0) }) else { break }
            text = String(text.dropFirst(courtesyPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalized = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        if ["add power", "add a power"].contains(normalized) { return .add("") }
        for prefix in ["add a power ", "add power "] where text.lowercased().hasPrefix(prefix) {
            return .add(String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if ["list powers", "show powers", "list my powers", "show my powers"].contains(normalized) { return .list }
        if ["dismiss media", "stop media", "close media", "stop animation"].contains(normalized) { return .dismissMedia }
        if text.lowercased().hasPrefix("import power media ") {
            let argument = String(text.dropFirst("import power media ".count))
            guard let separator = argument.range(of: " as ", options: [.caseInsensitive, .backwards]) else { return nil }
            let path = argument[..<separator.lowerBound].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            let identifier = argument[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), PaceManagedPowerStore.safeIdentifier(identifier) else { return nil }
            return .importMedia(path, identifier)
        }
        if normalized.hasPrefix("run the "), normalized.hasSuffix(" power") {
            let commandText = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            let name = String(commandText.dropFirst(8).dropLast(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return .run(name) }
        }
        for (prefix, action) in [
            ("show power ", 0), ("create power ", 1), ("create a power ", 1), ("update power ", 2),
            ("enable power ", 3), ("disable power ", 4), ("delete power ", 5),
            ("remove power ", 5), ("run power ", 6),
        ] {
            guard text.lowercased().hasPrefix(prefix) else { continue }
            let argument = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !argument.isEmpty else { return nil }
            let normalizedArgument = argument.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            let systemPowerPhrases = ["nap", "saving", "management", "supply", "consumption", "settings", "mode", "options"]
            if action != 1 && action != 2 && systemPowerPhrases.contains(where: { normalizedArgument == $0 || normalizedArgument.hasPrefix($0 + " ") }) && !isKnownSavedPowerName(argument) {
                return nil
            }
            switch action {
            case 0: return .show(argument)
            case 1: return .create(argument)
            case 2:
                guard let separator = argument.range(of: ": ") else { return nil }
                let target = argument[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let description = argument[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !target.isEmpty, !description.isEmpty else { return nil }
                return .update(target, description)
            case 3: return .setEnabled(argument, true)
            case 4: return .setEnabled(argument, false)
            case 5: return .remove(argument)
            default: return .run(argument)
            }
        }
        return nil
    }
}

nonisolated struct PacePendingPowerDescription: Equatable {
    enum Resolution: Equatable { case description(String), cancelled, unrelated }
    let requestedAt: Date
    static let lifetime: TimeInterval = 120

    func resolve(_ transcript: String, now: Date = Date()) -> Resolution {
        guard now.timeIntervalSince(requestedAt) >= 0, now.timeIntervalSince(requestedAt) < Self.lifetime else { return .unrelated }
        let description = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = description.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        if ["cancel", "cancel that", "never mind", "nevermind", "stop", "forget it"].contains(normalized) { return .cancelled }
        guard !description.isEmpty, !description.hasSuffix("?"),
              PacePowerCommandParser.parse(description) == nil else { return .unrelated }
        let descriptionPrefixes = ["a power ", "the power ", "when i run ", "when i say ", "whenever ", "it should ", "call it ", "named ", "called ", "i want a power ", "i want it to "]
        return descriptionPrefixes.contains(where: normalized.hasPrefix) ? .description(description) : .unrelated
    }
}

nonisolated struct PaceManagedPower: Equatable {
    let identifier: String
    let name: String
    let summary: String
    let reference: PaceAutomationCatalogReference?
    let ownedArtifactURL: URL?
    let fingerprint: String?
    let isEnabled: Bool
    let isManagedUserArtifact: Bool
    let managementStateError: String?
    var isUserOwned: Bool { ownedArtifactURL != nil }
    var capabilities: String {
        if isUserOwned { return "read, run, update, enable, disable, archive" }
        return reference == nil ? "read; configure in its existing settings or provider" : "read, run; configure in its existing settings or provider"
    }
}

nonisolated enum PacePowerDraft {
    case automation(PaceAutomationDefinition)
    case program(PaceProgramDefinition)
    case skill(PaceSkillFile)
}

nonisolated enum PaceManagedPowerError: Error, LocalizedError {
    case missing, ambiguous([String]), protected, changed, invalid(String), collision, stateUnavailable
    case archiveRecoveryRequired(String)
    var errorDescription: String? {
        switch self {
        case .stateUnavailable: return "Power settings are unreadable. Saved custom powers are blocked until their local settings are repaired."
        case .archiveRecoveryRequired(let path): return "The definition was archived, but settings cleanup failed and it could not be restored. Its recovery copy is at " + path
        case .missing: return "I couldn't find that exact power name or ID. Say list powers first."
        case .ambiguous(let identifiers): return "That name matches multiple powers. Use one exact ID: " + identifiers.joined(separator: ", ")
        case .protected: return "That power is protected. Use its existing settings or provider controls."
        case .changed: return "That power changed while I was working, so I didn't overwrite it."
        case .invalid(let message): return "I couldn't validate that power: " + message
        case .collision: return "That name or ID is already used. Choose another name; I didn't overwrite anything."
        }
    }
}

/// Management metadata wraps existing artifacts; their compilers and executors remain authoritative.
@MainActor
struct PaceManagedPowerStore {
    let automationDirectoryURL: URL
    let programDirectoryURL: URL
    let skillDirectoryURL: URL
    let recordsAudit: Bool
    let stateDirectoryURL: URL

    init(automationDirectoryURL: URL = PaceUserAutomationStore.defaultDirectoryURL,
         programDirectoryURL: URL = PaceUserProgramStore.defaultDirectoryURL,
         skillDirectoryURL: URL? = nil,
         stateDirectoryURL: URL? = nil, recordsAudit: Bool = true) {
        self.recordsAudit = recordsAudit
        self.automationDirectoryURL = automationDirectoryURL
        self.programDirectoryURL = programDirectoryURL
        self.skillDirectoryURL = skillDirectoryURL ?? PaceSkillLoader.userSkillsDirectory()
        self.stateDirectoryURL = stateDirectoryURL ?? automationDirectoryURL.deletingLastPathComponent().appendingPathComponent("power-management", isDirectory: true)
    }

    private struct State: Codable {
        var disabledIdentifiers: Set<String> = []
    }
    private var stateURL: URL { stateDirectoryURL.appendingPathComponent("state.json") }
    private func validateDirectoryChain(_ directoryURL: URL) throws {
        // URL.standardizedFileURL rewrites macOS /private/var back to /var.
        // Walk literal ancestors so an OS alias cannot hide a managed child link.
        var ancestorPath = directoryURL.path
        let systemAliases = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"]
        while !ancestorPath.isEmpty && ancestorPath != "/" {
            let ancestorURL = URL(fileURLWithPath: ancestorPath)
            if Self.isSymbolicLink(at: ancestorURL) {
                let linkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: ancestorPath)
                let absoluteLinkDestination = linkDestination.hasPrefix("/") ? linkDestination : "/" + linkDestination
                guard systemAliases[ancestorPath] == absoluteLinkDestination else {
                    throw PaceManagedPowerError.invalid("a managed directory is a symbolic link")
                }
            }
            ancestorPath = (ancestorPath as NSString).deletingLastPathComponent
        }
    }
    private func readState() throws -> State {
        do { return try readStateUnchecked() }
        catch { throw PaceManagedPowerError.stateUnavailable }
    }
    private func readStateUnchecked() throws -> State {
        try validateDirectoryChain(stateDirectoryURL)
        if Self.isSymbolicLink(at: stateURL) {
            throw PaceManagedPowerError.invalid("management state is a symbolic link")
        }
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return State() }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
    }
    func isEnabled(_ identifier: String) -> Bool {
        // Corrupt/unreadable management state must never silently re-enable work.
        guard let state = try? readState() else { return false }
        return !state.disabledIdentifiers.contains(ownedStateKey(identifier)) && !state.disabledIdentifiers.contains(identifier)
    }
    private func ownedStateKey(_ identifier: String) -> String { "owned:" + identifier }
    private func clearDisabledState(_ identifier: String, in state: inout State) {
        state.disabledIdentifiers.remove(identifier)
        state.disabledIdentifiers.remove(ownedStateKey(identifier))
    }
    private func writeState(_ state: State) throws {
        try validateDirectoryChain(stateDirectoryURL)
        try FileManager.default.createDirectory(at: stateDirectoryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
    nonisolated static func existsWithoutFollowingSymlinks(at url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
    }
    nonisolated static func isSymbolicLink(at url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0 && information.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
    }
    nonisolated static func isRegularFileWithoutFollowingSymlinks(at url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0 && information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
    nonisolated static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func safeIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier == PaceFlowStore.slug(for: identifier)
    }
    static func identifier(for entry: PaceAutomationCatalogEntry) -> String {
        switch entry.reference {
        case .typedDefinition(let identifier): return "\(entry.source == .user ? "automation" : "bundled"):\(identifier)"
        case .program(let identifier): return "program:\(identifier)"
        case .skill(let slug, _): return "skill:\(slug)"
        case .recordedFlow(let name): return "flow:\(name)"
        case .shortcut(let name): return "shortcut:\(name)"
        }
    }
    private func artifactURL(for entry: PaceAutomationCatalogEntry) -> URL? {
        let identifier: String
        let directoryURL: URL
        let suffix: String
        switch entry.reference {
        case .typedDefinition(let value) where entry.source == .user:
            identifier = value; directoryURL = automationDirectoryURL; suffix = ".json"
        case .program(let value):
            identifier = value; directoryURL = programDirectoryURL; suffix = ".json"
        case .skill(let value, _):
            identifier = value; directoryURL = skillDirectoryURL; suffix = ".skill.md"
        default: return nil
        }
        guard Self.safeIdentifier(identifier), (try? validateDirectoryChain(directoryURL)) != nil else { return nil }
        let url = directoryURL.appendingPathComponent(identifier + suffix)
        // A user-directory symlink is not an owned artifact. Never follow it for mutation.
        guard Self.isRegularFileWithoutFollowingSymlinks(at: url) else { return nil }
        return url
    }
    nonisolated static func exactSpokenTargetCandidates(_ requestedTarget: String) -> [String] {
        var candidate = requestedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [candidate]
        for _ in 0..<3 {
            guard let lastCharacter = candidate.last, ".!?".contains(lastCharacter) else { break }
            candidate.removeLast()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { break }
            candidates.append(candidate)
        }
        return candidates
    }

    func savedPowerNames() -> [String] {
        PaceUserAutomationStore(directoryURL: automationDirectoryURL).listValidDefinitions().map(\.name)
            + PaceUserProgramStore(directoryURL: programDirectoryURL).listValidPrograms().map(\.name)
            + PaceSkillLoader.listUserSkills(in: skillDirectoryURL).map(\.name)
    }

    func hasExactSavedPowerName(_ requestedName: String) -> Bool {
        let savedNames = savedPowerNames()
        return Self.exactSpokenTargetCandidates(requestedName).contains { candidate in
            savedNames.contains { PaceAutomationCatalog.normalizedName($0) == PaceAutomationCatalog.normalizedName(candidate) }
        }
    }

    private func isManagedUserArtifact(_ entry: PaceAutomationCatalogEntry) -> Bool {
        switch entry.reference {
        case .typedDefinition: return entry.source == .user
        case .program: return true
        case .skill(let slug, _):
            guard Self.safeIdentifier(slug) else { return false }
            return Self.existsWithoutFollowingSymlinks(at: skillDirectoryURL.appendingPathComponent(slug + ".skill.md"))
        default: return false
        }
    }

    func list(catalog: PaceAutomationCatalog) -> [PaceManagedPower] {
        let compiled = PacePowerCatalog.preinstalled.powers.map {
            PaceManagedPower(identifier: $0.identifier, name: $0.title, summary: $0.summary,
                reference: nil, ownedArtifactURL: nil, fingerprint: nil, isEnabled: true,
                isManagedUserArtifact: false, managementStateError: nil)
        }
        return compiled + catalog.entries.map { entry in
            let identifier = Self.identifier(for: entry)
            let artifactURL = artifactURL(for: entry)
            let requiresOwnedState = isManagedUserArtifact(entry)
            let stateError = requiresOwnedState && (try? readState()) == nil ? PaceManagedPowerError.stateUnavailable.localizedDescription : nil
            return PaceManagedPower(identifier: identifier, name: entry.name, summary: entry.description,
                reference: entry.reference, ownedArtifactURL: artifactURL,
                fingerprint: artifactURL.flatMap { try? Data(contentsOf: $0) }.map(Self.fingerprint),
                isEnabled: !requiresOwnedState || isEnabled(identifier),
                isManagedUserArtifact: requiresOwnedState, managementStateError: stateError)
        }
    }
    func resolve(_ exactNameOrIdentifier: String, catalog: PaceAutomationCatalog) throws -> PaceManagedPower {
        let powers = list(catalog: catalog)
        for candidate in Self.exactSpokenTargetCandidates(exactNameOrIdentifier) {
            if let exactIdentifierMatch = powers.first(where: { $0.identifier == candidate }) { return exactIdentifierMatch }
            let normalized = PaceAutomationCatalog.normalizedName(candidate)
            let matches = powers.filter { PaceAutomationCatalog.normalizedName($0.name) == normalized }
            if matches.isEmpty { continue }
            guard matches.count == 1 else { throw PaceManagedPowerError.ambiguous(matches.map(\.identifier)) }
            return matches[0]
        }
        throw PaceManagedPowerError.missing
    }
    func authoringContext(for power: PaceManagedPower) throws -> String {
        let artifactURL = try validateCurrent(power)
        let data = try Data(contentsOf: artifactURL)
        guard data.count <= 64 * 1024, let content = String(data: data, encoding: .utf8) else {
            throw PaceManagedPowerError.invalid("this saved definition is too large for a bounded update")
        }
        struct ExistingPowerData: Encodable {
            let backingIdentifier: String
            let content: String
        }
        let quotedData = try JSONEncoder().encode(ExistingPowerData(backingIdentifier: power.identifier, content: content))
        guard let quotedJSON = String(data: quotedData, encoding: .utf8) else { throw PaceManagedPowerError.invalid("could not quote the saved definition") }
        return quotedJSON
    }

    func contentSummary(_ power: PaceManagedPower) throws -> String {
        guard power.isUserOwned else { return power.summary }
        let data = try Data(contentsOf: validateCurrent(power))
        switch power.reference {
        case .typedDefinition:
            let definition = try JSONDecoder().decode(PaceAutomationDefinition.self, from: data)
            return boundedDescription(try PaceAutomationCompiler.compile(definition).flattenedActions.map(\.approvalDescription).joined(separator: "; "))
        case .program:
            let program = try JSONDecoder().decode(PaceProgramDefinition.self, from: data)
            return boundedDescription(try describeProgramNodes(program.nodes))
        case .skill:
            guard let text = String(data: data, encoding: .utf8), let skill = PaceSkillLoader.parse(skillMarkdown: text) else { throw PaceManagedPowerError.changed }
            return boundedDescription(skill.steps.enumerated().map { "Step \($0.offset + 1): \($0.element.instruction)" }.joined(separator: "; "))
        default: return power.summary
        }
    }

    private func boundedDescription(_ description: String) -> String {
        description.count > 1800 ? String(description.prefix(1800)) + "… Further steps are saved in the local definition." : description
    }
    private func describeProgramNodes(_ nodes: [PaceProgramNode]) throws -> String {
        try nodes.map { node in
            switch node {
            case .javascript: return "Computes locally using JavaScript; may speak text and present saved local media."
            case .action(let step):
                let definition = PaceAutomationDefinition(schemaVersion: 1, identifier: "inspection", name: "Inspection", description: "Inspection", category: "custom",
                    source: .user, executionMode: .deterministicLocal, requiredPreferences: [], steps: [step])
                return try PaceAutomationCompiler.compile(definition).flattenedActions.map(\.approvalDescription).joined(separator: ", ")
            case .condition(let predicate, let thenNodes, let otherwiseNodes):
                let condition: String
                switch predicate {
                case .weekdayIn(let weekdays): condition = "weekday number is one of " + weekdays.map(String.init).joined(separator: ", ") + " (Sunday is one)"
                case .localHourIn(let startInclusive, let endExclusive): condition = "local hour is at least \(startInclusive) and before \(endExclusive)"
                case .frontmostApplicationIn(let bundleIdentifiers): condition = "frontmost app is " + bundleIdentifiers.joined(separator: ", ")
                }
                return "If \(condition): \(try describeProgramNodes(thenNodes)); otherwise: \(try describeProgramNodes(otherwiseNodes))"
            case .repeatTimes(let count, let repeatedNodes): return "Repeat \(count) times: \(try describeProgramNodes(repeatedNodes))"
            }
        }.joined(separator: "; ")
    }

    func validateCurrent(_ power: PaceManagedPower) throws -> URL {
        guard let artifactURL = power.ownedArtifactURL, let fingerprint = power.fingerprint else { throw PaceManagedPowerError.protected }
        try validateDirectoryChain(artifactURL.deletingLastPathComponent())
        guard Self.isRegularFileWithoutFollowingSymlinks(at: artifactURL),
              let bytes = try? Data(contentsOf: artifactURL), Self.fingerprint(bytes) == fingerprint else { throw PaceManagedPowerError.changed }
        return artifactURL
    }
    func setEnabled(_ enabled: Bool, power: PaceManagedPower) throws {
        _ = try validateCurrent(power)
        var state = try readState()
        if enabled { clearDisabledState(power.identifier, in: &state) }
        else { state.disabledIdentifiers.insert(ownedStateKey(power.identifier)) }
        try writeState(state)
        audit(enabled ? "enable" : "disable", power.identifier)
    }
    @discardableResult
    func archive(_ power: PaceManagedPower) throws -> URL {
        let originalURL = try validateCurrent(power)
        var state = try readState()
        let archiveDirectoryURL = stateDirectoryURL.appendingPathComponent("archive", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try validateDirectoryChain(archiveDirectoryURL)
        try FileManager.default.createDirectory(at: archiveDirectoryURL, withIntermediateDirectories: true)
        let archiveURL = archiveDirectoryURL.appendingPathComponent(originalURL.lastPathComponent)
        try FileManager.default.moveItem(at: originalURL, to: archiveURL)
        clearDisabledState(power.identifier, in: &state)
        do { try writeState(state) }
        catch {
            do { try FileManager.default.moveItem(at: archiveURL, to: originalURL) }
            catch { throw PaceManagedPowerError.archiveRecoveryRequired(archiveURL.path) }
            throw PaceManagedPowerError.stateUnavailable
        }
        audit("archive", power.identifier)
        return archiveURL
    }

    /// Updates preserve identity and representation; validation runs before the atomic replacement.
    func commit(_ draft: PacePowerDraft, replacing power: PaceManagedPower? = nil, catalog: PaceAutomationCatalog) throws -> String {
        let destinationURL: URL
        let encodedData: Data
        let identifier: String
        let name: String
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        switch draft {
        case .automation(let authored):
            guard power == nil || power?.identifier.hasPrefix("automation:") == true else { throw PaceManagedPowerError.invalid("keep this power's existing representation") }
            let stableIdentifier = power.map { String($0.identifier.dropFirst("automation:".count)) } ?? authored.identifier
            let definition = PaceAutomationDefinition(schemaVersion: authored.schemaVersion, identifier: stableIdentifier,
                name: power?.name ?? authored.name, description: authored.description, category: authored.category,
                invocationPhrases: authored.invocationPhrases, source: .user, executionMode: .deterministicLocal,
                requiredPreferences: authored.requiredPreferences, steps: authored.steps)
            _ = try PaceAutomationCompiler.compile(definition)
            identifier = stableIdentifier; name = definition.name
            destinationURL = automationDirectoryURL.appendingPathComponent(identifier + ".json")
            encodedData = try encoder.encode(definition)
        case .program(let authored):
            guard power == nil || power?.identifier.hasPrefix("program:") == true else { throw PaceManagedPowerError.invalid("keep this power's existing representation") }
            let stableIdentifier = power.map { String($0.identifier.dropFirst("program:".count)) } ?? authored.identifier
            let program = PaceProgramDefinition(schemaVersion: authored.schemaVersion, identifier: stableIdentifier,
                name: power?.name ?? authored.name, description: authored.description, category: authored.category,
                invocationPhrases: authored.invocationPhrases, requiredPreferences: authored.requiredPreferences, nodes: authored.nodes)
            let issues = PaceProgramValidator.validationIssues(for: program)
            guard issues.isEmpty else { throw PaceManagedPowerError.invalid(issues.map(\.message).joined(separator: "; ")) }
            identifier = stableIdentifier; name = program.name
            destinationURL = programDirectoryURL.appendingPathComponent(identifier + ".json")
            encodedData = try encoder.encode(program)
        case .skill(let authored):
            guard power == nil || power?.identifier.hasPrefix("skill:") == true else { throw PaceManagedPowerError.invalid("keep this power's existing representation") }
            let stableIdentifier = power.map { String($0.identifier.dropFirst("skill:".count)) } ?? authored.slug
            let skill = PaceSkillFile(name: power?.name ?? authored.name, slug: stableIdentifier,
                description: authored.description, category: authored.category, requiredPreferences: authored.requiredPreferences,
                trigger: authored.trigger, steps: authored.steps, notes: authored.notes)
            let markdown = PaceSkillLoader.serialize(skill)
            guard !skill.steps.isEmpty, PaceSkillLoader.parse(skillMarkdown: markdown) == skill else { throw PaceManagedPowerError.invalid("skill must round-trip without losing content") }
            identifier = stableIdentifier; name = skill.name
            destinationURL = skillDirectoryURL.appendingPathComponent(identifier + ".skill.md")
            encodedData = Data(markdown.utf8)
        }
        guard Self.safeIdentifier(identifier) else { throw PaceManagedPowerError.invalid("invalid artifact identifier") }
        try validateDirectoryChain(destinationURL.deletingLastPathComponent())
        let otherEntries = catalog.entries.filter { Self.identifier(for: $0) != power?.identifier }
        guard !PacePowerCatalog.preinstalled.powers.contains(where: { PaceAutomationCatalog.normalizedName($0.title) == PaceAutomationCatalog.normalizedName(name) }), !otherEntries.contains(where: {
            PaceAutomationCatalog.normalizedName($0.name) == PaceAutomationCatalog.normalizedName(name)
                || Self.identifier(for: $0).split(separator: ":").last.map(String.init) == identifier
        }) else { throw PaceManagedPowerError.collision }
        if let power {
            let originalURL = try validateCurrent(power)
            guard originalURL.standardizedFileURL == destinationURL.standardizedFileURL else { throw PaceManagedPowerError.protected }
        } else if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw PaceManagedPowerError.collision
        }
        if let power {
            let originalURL = try validateCurrent(power)
            let revisionDirectoryURL = stateDirectoryURL.appendingPathComponent("revisions", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try validateDirectoryChain(revisionDirectoryURL)
            try FileManager.default.createDirectory(at: revisionDirectoryURL, withIntermediateDirectories: true)
            try Data(contentsOf: originalURL).write(to: revisionDirectoryURL.appendingPathComponent(originalURL.lastPathComponent), options: .atomic)
        }
        let stateForCreate = power == nil ? try readState() : nil
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encodedData.write(to: destinationURL, options: .atomic)
        if var state = stateForCreate {
            let namespace: String
            switch draft {
            case .automation: namespace = "automation:"
            case .program: namespace = "program:"
            case .skill: namespace = "skill:"
            }
            clearDisabledState(namespace + identifier, in: &state)
            do { try writeState(state) }
            catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw PaceManagedPowerError.stateUnavailable
            }
        }
        audit(power == nil ? "create" : "update", power?.identifier ?? identifier)
        return name
    }
    private func audit(_ operation: String, _ identifier: String) {
        guard recordsAudit else { return }
        PaceAPIAuditLog.shared.record(subsystem: "power-management", operation: operation, target: identifier,
            durationMilliseconds: 0, outcome: "ok")
    }
}
