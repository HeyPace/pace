//
//  PaceSkillsView.swift
//  leanring-buddy
//
//  Skills sidebar tab for PaceMainWindow. Auto-generated from one
//  source of truth per category:
//
//    - Local skills      ← PaceToolRegistry.localTools
//    - MCP skills (per server) ← PaceMCPServerRegistry.loadConfiguredServers()
//
//  Drift-proof by construction: the new `exampleUtterance` field on
//  every PaceLocalToolDefinition is validated at startup, so an empty
//  utterance crashes the app before users can see this tab.
//
//  Searchable. Each row has copy-to-clipboard for the example utterance.
//  MCP servers are listed by name; tool-level introspection (a real
//  tools/list probe) needs an async stdio handshake — deliberately
//  deferred to v2 because the v1 win is "show the user that MCP exists
//  and which servers are wired up", not "render every MCP tool name".
//

import AppKit
import SaaSMakerUI
import SwiftUI

// MARK: - PaceSkillsView

struct PaceSkillsView: View {
    let companionManager: CompanionManager
    let openConnection: (PacePowerConnection) -> Void
    var onManageConnections: (() -> Void)? = nil
    @State private var showsBuiltInPowers = false
    @State private var searchQuery: String = ""
    @State private var connections: [PacePowerConnection] = []
    @State private var showsActions = false
    @State private var lastCopiedExampleUtteranceSlug: String? = nil

    @State private var pendingDeletion: SavedPowerDeletion?
    @State private var deletionError: String?

    private enum SavedPowerDeletion: Identifiable {
        case skill(PaceSkillFile)
        case program(PaceProgramDefinition)

        var id: String {
            switch self {
            case .skill(let skill): "skill:" + skill.slug
            case .program(let program): "program:" + program.identifier
            }
        }

        var name: String {
            switch self {
            case .skill(let skill): skill.name
            case .program(let program): program.name
            }
        }
    }

    private struct WorkflowRow: Identifiable {
        let entry: PaceChatPowerCatalog.Entry
        let catalogEntry: PaceAutomationCatalogEntry
        let program: PaceProgramDefinition?
        let skill: PaceSkillFile?

        var id: String { entry.id }
    }

    @State private var workflows: [WorkflowRow] = []
    @State private var catalogRevision = 0
    @State private var catalogLoaded = false

    // "Teach a skill" form draft state (the typed sibling of the voice path).
    @State private var isTeachFormExpanded: Bool = false
    @State private var teachDraftName: String = ""
    @State private var teachDraftSteps: String = ""
    @State private var teachDraftTrigger: String = ""
    @State private var teachFeedbackMessage: String? = nil

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                searchField
                if !searching || !matchingPowers.isEmpty { builtInPowersSection }
                if !searching || isTeachFormExpanded || !savedRows.isEmpty {
                    yourSkillsSection
                }
                if !installedRows.isEmpty { installedWorkflowsSection }
                if !searching || !matchingConnections.isEmpty { mcpSkillsSection }
                if !searching || !filteredLocalTools().isEmpty { localSkillsSection }
                if !catalogLoaded { ProgressView("Loading workflows…").controlSize(.small) }
                if catalogLoaded && searching && matchingPowers.isEmpty && savedRows.isEmpty && installedRows.isEmpty
                    && matchingConnections.isEmpty && filteredLocalTools().isEmpty
                {
                    ContentUnavailableView.search(text: searchQuery)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Colors.surface)
        .safeAreaInset(edge: .bottom) {
            if let deletionError {
                HStack(alignment: .top, spacing: 10) {
                    Label(deletionError, systemImage: "exclamationmark.triangle")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { self.deletionError = nil }.pointerCursor()
                }
                .padding(12)
                .background(DS.Colors.controlFill)
            }
        }
        .alert(item: $pendingDeletion) { selected in
            Alert(
                title: Text("Delete “\(selected.name)”?"),
                message: Text("This removes the saved power from this Mac."),
                primaryButton: .cancel(),
                secondaryButton: .destructive(Text("Delete")) { deleteConfirmedPower(selected) })
        }
        .onAppear {
            connections = PacePowerConnection.configured()
        }
        .task(id: catalogRevision) {
            let needsShortcuts = PaceShortcutsAutomationProvider.shared.cachedCatalogIfFresh() == nil
            await updateWorkflows(refreshShortcuts: false, keepPriorShortcuts: needsShortcuts)
            if needsShortcuts && !Task.isCancelled {
                await updateWorkflows(refreshShortcuts: true, keepPriorShortcuts: false)
            }
        }
    }

    private func updateWorkflows(refreshShortcuts: Bool, keepPriorShortcuts: Bool) async {
        let discovered = await companionManager.discoverAutomationCatalog(
            refreshShortcutCatalog: refreshShortcuts, warmShortcutCache: false)
        guard !Task.isCancelled else { return }
        let byIdentifier = Dictionary(
            discovered.catalog.entries.map { (PaceManagedPowerStore.identifier(for: $0), $0) },
            uniquingKeysWith: { first, _ in first })
        let skills = Dictionary(discovered.skills.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let programs = Dictionary(
            discovered.programs.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let discoveredRows: [WorkflowRow] = companionManager.managedPowerStore.list(catalog: discovered.catalog)
            .compactMap { power in
                guard let reference = power.reference, let catalogEntry = byIdentifier[power.identifier],
                    seen.insert(power.identifier).inserted
                else { return nil }
                var program: PaceProgramDefinition?
                var skill: PaceSkillFile?
                switch reference {
                case .program(let identifier): program = programs[identifier]
                case .skill(let slug, _): skill = skills[slug]
                default: break
                }
                return WorkflowRow(
                    entry: .init(power: power), catalogEntry: catalogEntry, program: program, skill: skill)
            }
        let priorShortcuts =
            keepPriorShortcuts
            ? workflows.filter { row in
                if case .shortcut = row.catalogEntry.reference { return !seen.contains(row.id) }
                return false
            } : []
        workflows = discoveredRows + priorShortcuts
        catalogLoaded = true
    }

    // MARK: - Header + search

    private var query: String { searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searching: Bool { !query.isEmpty }

    private var matchingPowers: [PacePowerDefinition] {
        PacePowerCatalog.preinstalled.powers.filter { power in
            !searching || ([power.title, power.summary] + power.tools.map(\.canonicalName)).contains { matches($0) }
        }
    }

    private func matches(_ value: String) -> Bool {
        value.localizedStandardContains(query)
            || value.replacingOccurrences(of: "_", with: " ").localizedStandardContains(query)
    }

    @FocusState private var searchFieldIsFocused: Bool

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search powers, workflows, actions, and connections…", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFieldIsFocused)
                .accessibilityLabel("Search powers, workflows, actions, and connections")
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    searchFieldIsFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .paceControlHoverHighlight(cornerRadius: 4)
                .pointerCursor()
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(searchFieldIsFocused ? Color.accentColor : DS.Colors.textTertiary.opacity(0.35))
                .allowsHitTesting(false)
        }
    }

    private var builtInPowersSection: some View {
        let powers = PacePowerCatalog.preinstalled.powers
        let matching = matchingPowers
        return VStack(alignment: .leading, spacing: 8) {
            if query.isEmpty {
                Button {
                    showsBuiltInPowers.toggle()
                } label: {
                    Label(
                        "Built-in powers (\(powers.count))",
                        systemImage: showsBuiltInPowers ? "chevron.down" : "chevron.right"
                    )
                    .font(DS.Typography.sectionTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .paceControlHoverHighlight(cornerRadius: 5)
                .pointerCursor()
                .accessibilityValue(showsBuiltInPowers ? "Expanded" : "Collapsed")
            } else if !matching.isEmpty {
                Text("Built-in powers (\(matching.count) of \(powers.count))").font(DS.Typography.sectionTitle)
            }
            if showsBuiltInPowers || !query.isEmpty {
                ForEach(matching) { power in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(power.title).font(.callout.weight(.semibold))
                        Text(power.summary).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // MARK: - Your skills (taught .skill.md skills)

    private var yourSkillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workflowHeading(.saved, matches: savedRows.count))
                        .font(DS.Typography.sectionTitle)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer()
                Button(isTeachFormExpanded ? "Cancel" : "Teach a power") {
                    withAnimation { isTeachFormExpanded.toggle() }
                    if !isTeachFormExpanded { clearTeachDraft() }
                }
                .buttonStyle(.borderless)
                .pointerCursor()
            }

            if isTeachFormExpanded {
                teachSkillForm
            }

            VStack(spacing: 0) {
                workflowList(savedRows)
                if catalogLoaded && savedRows.isEmpty && !isTeachFormExpanded && !searching {
                    Text("Teach Pace a step-by-step workflow to save it here.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                }
            }

        }
    }

    private var installedWorkflowsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workflowHeading(.installed, matches: installedRows.count))
                .font(DS.Typography.sectionTitle).accessibilityAddTraits(.isHeader)
            workflowList(installedRows)
        }
    }

    private func workflowList(_ rows: [WorkflowRow]) -> some View {
        ForEach(rows) { row in
            if let program = row.program, row.entry.actions.contains(.archive) {
                programmedSkillRow(program: program)
            } else if let skill = row.skill {
                taughtSkillRow(skill: skill, isDeletable: row.entry.actions.contains(.archive))
            } else {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.entry.summary)
                        Text(row.catalogEntry.invocationPhrases.joined(separator: " · "))
                        Text(row.entry.isEnabled ? "Enabled" : "Disabled")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    HStack {
                        Text(row.entry.name)
                        Spacer()
                        Text(row.entry.source).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .pointerCursor()
                .padding(.vertical, 6)
            }
            Divider().opacity(0.25)
        }
    }

    private var teachSkillForm: some View {
        SMCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Power name (e.g. Start My Day)", text: $teachDraftName)
                    .textFieldStyle(.roundedBorder)
                TextField("Trigger phrase — optional (e.g. start my day)", text: $teachDraftTrigger)
                    .textFieldStyle(.roundedBorder)
                Text("Steps, one per line")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextEditor(text: $teachDraftSteps)
                    .font(DS.Typography.metadata)
                    .frame(minHeight: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                HStack {
                    if let teachFeedbackMessage {
                        Text(teachFeedbackMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Save power") { saveTaughtSkillFromForm() }
                        .buttonStyle(.borderedProminent)
                        .pointerCursor()
                        .disabled(
                            teachDraftName.trimmingCharacters(in: .whitespaces).isEmpty
                                || teachDraftSteps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
        }
    }

    private func taughtSkillRow(skill: PaceSkillFile, isDeletable: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 13, weight: .medium))
                    if !isDeletable {
                        SMStatusPill("built-in")
                    }
                }
                Text(skill.description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "list.number")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\(skill.steps.count) step\(skill.steps.count == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    if let trigger = skill.trigger, !trigger.isEmpty {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("\u{201C}\(trigger)\u{201D}")
                            .font(.system(size: 12, design: .serif))
                            .italic()
                            .foregroundColor(.primary)
                    }
                }
            }
            Spacer()
            if isDeletable {
                Button(role: .destructive) {
                    deletionError = nil
                    pendingDeletion = .skill(skill)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel("Delete " + skill.name)
                .help("Delete this saved power")
            }
        }
        .padding(.vertical, 10)
    }

    private func programmedSkillRow(program: PaceProgramDefinition) -> some View {
        let maximumActionStepCount = PaceProgramValidator
            .worstCaseExpandedActionSteps(for: program)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(program.name)
                        .font(.system(size: 13, weight: .medium))
                    Text("Program")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14))
                        .clipShape(Capsule())
                }
                Text(program.description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("up to \(maximumActionStepCount) action step\(maximumActionStepCount == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    if let invocationPhrase = program.invocationPhrases.first {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("“\(invocationPhrase)”")
                            .font(.system(size: 12, design: .serif))
                            .italic()
                            .foregroundColor(.primary)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                deletionError = nil
                pendingDeletion = .program(program)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Delete " + program.name)
            .help("Delete this saved program")
        }
        .padding(.vertical, 10)
    }

    // MARK: - Your-skills data + actions

    private var savedRows: [WorkflowRow] { filteredWorkflows(.saved) }
    private var installedRows: [WorkflowRow] { filteredWorkflows(.installed) }

    private func filteredWorkflows(_ category: PaceChatPowerCatalog.Category) -> [WorkflowRow] {
        workflows.filter { row in
            guard row.entry.category == category else { return false }
            let terms =
                [row.entry.name, row.entry.source, row.entry.summary, row.catalogEntry.category]
                + row.catalogEntry.invocationPhrases
            return !searching || terms.contains(where: matches)
        }
    }

    private func workflowHeading(_ category: PaceChatPowerCatalog.Category, matches: Int) -> String {
        guard catalogLoaded else { return category.title }
        let total = workflows.filter { $0.entry.category == category }.count
        return searching ? "\(category.title) (\(matches) of \(total))" : "\(category.title) (\(total))"
    }

    private func clearTeachDraft() {
        teachDraftName = ""
        teachDraftSteps = ""
        teachDraftTrigger = ""
        teachFeedbackMessage = nil
    }

    private func saveTaughtSkillFromForm() {
        guard let skill = PaceSkillLoader.skillFromForm(
            name: teachDraftName,
            stepsText: teachDraftSteps,
            trigger: teachDraftTrigger,
            notes: nil
        ) else {
            teachFeedbackMessage = "Add a name and at least one step."
            return
        }
        do {
            try PaceSkillLoader.save(skill, to: companionManager.managedPowerStore.skillDirectoryURL)
            catalogRevision += 1
            clearTeachDraft()
            withAnimation { isTeachFormExpanded = false }
        } catch {
            teachFeedbackMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func deleteConfirmedPower(_ selected: SavedPowerDeletion) {
        defer { catalogRevision += 1 }
        do {
            // Recheck the selected version in case another window or process replaced it during confirmation.
            switch selected {
            case .skill(let skill):
                guard !skill.slug.contains("/") else {
                    deletionError = "Couldn’t identify the saved file for “\(skill.name)”."
                    return
                }
                let filename = skill.slug + ".skill.md"
                let url = companionManager.managedPowerStore.skillDirectoryURL.appendingPathComponent(filename)
                let contents = try String(contentsOf: url, encoding: .utf8)
                guard
                    PaceSkillLoader.parse(
                        skillMarkdown: contents, fallbackSlug: url.deletingPathExtension().lastPathComponent) == skill
                else {
                    deletionError = "“\(skill.name)” changed. Review the current power before deleting it."
                    return
                }
                try PaceSkillLoader.deleteUserSkill(
                    slug: skill.slug, in: companionManager.managedPowerStore.skillDirectoryURL)
            case .program(let program):
                let store = PaceUserProgramStore(directoryURL: companionManager.managedPowerStore.programDirectoryURL)
                guard store.listValidPrograms().contains(program) else {
                    deletionError =
                        "Couldn’t verify the current version of “\(program.name)”. Review the list before trying again."
                    return
                }
                try store.delete(identifier: program.identifier)
            }
            deletionError = nil
        } catch {
            deletionError = "Couldn’t delete “\(selected.name)”. " + error.localizedDescription
        }
    }

    // MARK: - Local skills

    private var localSkillsSection: some View {
        let tools = filteredLocalTools()
        return VStack(alignment: .leading, spacing: 8) {
            if searching {
                Text("Built-in actions (\(tools.count) of \(PaceToolRegistry.localTools.count))")
                    .font(DS.Typography.sectionTitle).accessibilityAddTraits(.isHeader)
            } else {
                Button {
                    showsActions.toggle()
                } label: {
                    Label(
                        "Built-in actions (\(tools.count))",
                        systemImage: showsActions ? "chevron.down" : "chevron.right"
                    )
                    .font(DS.Typography.sectionTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(.plain).paceControlHoverHighlight(cornerRadius: DS.Radius.control).pointerCursor()
                .accessibilityValue(showsActions ? "Expanded" : "Collapsed")
            }
            if searching || showsActions {
                ForEach(tools, id: \.canonicalName) { definition in
                    localSkillRow(definition: definition)
                    Divider().opacity(0.25)
                }
            }
        }
    }

    private func localSkillRow(definition: PaceLocalToolDefinition) -> some View {
        let isCopiedRecently = lastCopiedExampleUtteranceSlug == definition.canonicalName
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PaceChatTranscriptModel.toolDisplayName(fromRawToolName: definition.canonicalName))
                    .font(.system(size: 13, weight: .medium))
                Text(definition.description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\u{201C}\(definition.exampleUtterance)\u{201D}")
                        .font(.system(size: 12, design: .serif))
                        .italic()
                        .foregroundColor(.primary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(definition.riskLevel.displayName.lowercased())
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(riskBadgeBackground(for: definition.riskLevel))
                    .clipShape(Capsule())
                Button(action: {
                    copyExampleUtteranceToClipboard(slug: definition.canonicalName, text: definition.exampleUtterance)
                }) {
                    Image(systemName: isCopiedRecently ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .paceControlHoverHighlight(cornerRadius: DS.Radius.control).pointerCursor()
                .accessibilityLabel(isCopiedRecently ? "Copied" : "Copy example")
                .help(isCopiedRecently ? "Copied" : "Copy example")
            }
        }
        .padding(.vertical, 10)
    }

    private func riskBadgeBackground(for riskLevel: PaceToolRiskLevel) -> Color {
        switch riskLevel {
        case .readOnly:
            return Color.green.opacity(0.18)
        case .appOrSystemMutation:
            return Color.blue.opacity(0.18)
        case .inputInjection:
            return Color.orange.opacity(0.18)
        case .destructive:
            return Color.red.opacity(0.22)
        case .externalIntegration:
            return Color.purple.opacity(0.18)
        }
    }

    private func filteredLocalTools() -> [PaceLocalToolDefinition] {
        guard searching else { return PaceToolRegistry.localTools }
        return PaceToolRegistry.localTools.filter { definition in
            ([definition.canonicalName, definition.description, definition.exampleUtterance] + definition.aliases)
                .contains { matches($0) }
        }
    }

    private func copyExampleUtteranceToClipboard(slug: String, text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastCopiedExampleUtteranceSlug = slug
        // Reset the checkmark after a short delay so the user sees the
        // affirmation but the row goes back to its idle state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if lastCopiedExampleUtteranceSlug == slug {
                lastCopiedExampleUtteranceSlug = nil
            }
        }
    }

    // MARK: - MCP skills

    private var mcpSkillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(
                    searching
                        ? "Connections (\(matchingConnections.count) of \(connections.count))"
                        : "Connections (\(connections.count))"
                )
                .font(DS.Typography.sectionTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                if let onManageConnections {
                    Button("Manage connections", action: onManageConnections)
                        .buttonStyle(.bordered).pointerCursor()
                }
            }
            if connections.isEmpty {
                Text("No connections configured yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(matchingConnections, id: \.id) { connection in
                Button {
                    openConnection(connection)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(connection.name).font(.callout.weight(.medium))
                            Text(connection.summary).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
                .pointerCursor()
                .help("Open connection settings")
            }
        }
    }

    private var matchingConnections: [PacePowerConnection] {
        guard searching else { return connections }
        return connections.filter { connection in
            ([connection.id, connection.name, connection.summary] + connection.searchTerms).contains { matches($0) }
        }
    }
}
