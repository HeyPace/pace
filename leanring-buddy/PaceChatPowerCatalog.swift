import Foundation

/// Local presentation snapshot. Every action rechecks the current catalog before dispatch.
nonisolated struct PaceChatPowerCatalog: Codable, Equatable, Sendable {
    enum Category: String, Codable, CaseIterable, Sendable {
        case builtIn, saved, installed

        var title: String {
            switch self {
            case .builtIn: return "Built-in powers"
            case .saved: return "Saved powers"
            case .installed: return "Installed workflows"
            }
        }
    }

    enum Action: String, Codable, Sendable {
        case show, run, enable, disable, archive, update
    }

    struct Entry: Identifiable, Codable, Equatable, Sendable {
        let id: String
        let name: String
        let summary: String
        let source: String
        let category: Category
        let isEnabled: Bool
        let actions: [Action]
        var fingerprint: String? = nil

    }

    struct Selection: Equatable, Sendable {
        let action: Action
        let entry: Entry

        var command: PacePowerCommand? {
            guard entry.actions.contains(action) else { return nil }
            switch action {
            case .show: return .show(entry.id)
            case .run: return .run(entry.id)
            default: return nil
            }
        }

        @discardableResult
        func validate(in powers: [PaceManagedPower]) throws -> PaceManagedPower {
            let matches = powers.filter { $0.identifier == entry.id }
            guard command != nil, matches.count == 1, let current = matches.first else {
                throw PaceManagedPowerError.changed
            }
            let fresh = Entry(power: current)
            guard fresh.actions.contains(action) else { throw PaceManagedPowerError.changed }
            if action == .run {
                guard fresh == entry else { throw PaceManagedPowerError.changed }
            }
            return current
        }
    }

    let entries: [Entry]

    var plainTextSummary: String {
        let groups = Category.allCases.compactMap { category -> String? in
            let items = entries.filter { $0.category == category }
            guard !items.isEmpty else { return nil }
            let names = items.prefix(8).map(\.name).joined(separator: ", ")
            let remaining = items.count > 8 ? " and \(items.count - 8) more" : ""
            return "\(category.title): \(names)\(remaining)."
        }
        return ([countSummary] + groups + ["For details, say ‘show power’ followed by its name."])
            .joined(separator: "\n")
    }

    var countSummary: String {
        let builtIn = entries.filter { $0.category == .builtIn }.count
        let saved = entries.filter { $0.category == .saved }.count
        let installed = entries.filter { $0.category == .installed }.count
        return
            "\(builtIn) built-in \(builtIn == 1 ? "power" : "powers"), \(saved) saved \(saved == 1 ? "power" : "powers"), \(installed) installed \(installed == 1 ? "workflow" : "workflows")."
    }
}

extension PaceChatPowerCatalog.Entry {
    nonisolated init(power: PaceManagedPower) {
        id = power.identifier
        name = power.name
        summary = power.summary
        isEnabled = power.isEnabled
        fingerprint = power.fingerprint
        if power.reference == nil {
            category = .builtIn
        } else {
            category = power.isManagedUserArtifact || power.isUserOwned ? .saved : .installed
        }
        switch power.reference {
        case nil: source = "Built into Pace"
        case .typedDefinition: source = category == .saved ? "Saved automation" : "Bundled workflow"
        case .program: source = "Saved program"
        case .recordedFlow: source = "Recorded workflow"
        case .skill: source = "Step-by-step workflow"
        case .shortcut: source = "Apple Shortcuts"
        }
        var controls: [PaceChatPowerCatalog.Action] = [.show]
        if power.managementStateError == nil && (!power.isManagedUserArtifact || power.isUserOwned) {
            if power.reference != nil && power.isEnabled && (!power.isUserOwned || power.fingerprint != nil) {
                controls.append(.run)
            }
            if power.isUserOwned && power.fingerprint != nil {
                controls.append(contentsOf: [.update, power.isEnabled ? .disable : .enable, .archive])
            }
        }
        actions = controls
    }
}
