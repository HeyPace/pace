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
import SwiftUI

// MARK: - PaceSkillsView

struct PaceSkillsView: View {
    @State private var searchQuery: String = ""
    @State private var configuredMCPServerNames: [String] = []
    @State private var lastCopiedExampleUtteranceSlug: String? = nil

    // Taught skills (the `.skill.md` layer). `userTaughtSkills` are the ones
    // the user created — editable + deletable; `bundledSkills` ship with Pace
    // and are read-only.
    @State private var userTaughtSkills: [PaceSkillFile] = []
    @State private var bundledSkills: [PaceSkillFile] = []
    @State private var userPrograms: [PaceProgramDefinition] = []

    // "Teach a skill" form draft state (the typed sibling of the voice path).
    @State private var isTeachFormExpanded: Bool = false
    @State private var teachDraftName: String = ""
    @State private var teachDraftSteps: String = ""
    @State private var teachDraftTrigger: String = ""
    @State private var teachFeedbackMessage: String? = nil

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                sectionHeader
                searchField
                yourSkillsSection
                localSkillsSection
                if !configuredMCPServerNames.isEmpty {
                    mcpSkillsSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Colors.surface)
        .onAppear {
            configuredMCPServerNames = Array(PaceMCPServerRegistry
                .loadConfiguredServers()
                .keys)
                .sorted()
            reloadTaughtSkills()
        }
    }

    // MARK: - Header + search

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Automations")
                .font(DS.Typography.windowTitle)
                .tracking(-0.45)
                .foregroundStyle(DS.Colors.textPrimary)
            Text("Teach Pace a repeatable action in plain language, or browse what it can already run on this Mac.")
                .font(DS.Typography.body)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var searchField: some View {
        TextField("Search automations…", text: $searchQuery)
            .textFieldStyle(.roundedBorder)
    }

    // MARK: - Your skills (taught .skill.md skills)

    private var yourSkillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your automations")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Repeatable actions you taught Pace. Say a saved trigger phrase to run one.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(isTeachFormExpanded ? "Cancel" : "Teach an automation") {
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
                ForEach(filteredUserPrograms(), id: \.identifier) { program in
                    programmedSkillRow(program: program)
                    Divider().opacity(0.25)
                }
                ForEach(filteredUserSkills(), id: \.slug) { skill in
                    taughtSkillRow(skill: skill, isDeletable: true)
                    Divider().opacity(0.25)
                }
                if filteredUserPrograms().isEmpty
                    && filteredUserSkills().isEmpty
                    && !isTeachFormExpanded {
                    Text(searchQuery.isEmpty
                         ? "No taught automations yet. Describe one here or ask Pace to create one."
                         : "No taught automations match \u{201C}\(searchQuery)\u{201D}.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                }
            }

            if !filteredBundledSkills().isEmpty {
                Text("Built-in automations")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(filteredBundledSkills(), id: \.slug) { skill in
                        taughtSkillRow(skill: skill, isDeletable: false)
                        Divider().opacity(0.25)
                    }
                }
            }
        }
    }

    private var teachSkillForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Automation name (e.g. Start My Day)", text: $teachDraftName)
                .textFieldStyle(.roundedBorder)
            TextField("Trigger phrase — optional (e.g. start my day)", text: $teachDraftTrigger)
                .textFieldStyle(.roundedBorder)
            Text("Steps — one per line")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextEditor(text: $teachDraftSteps)
                .font(.system(size: 12, design: .monospaced))
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
                Button("Save automation") { saveTaughtSkillFromForm() }
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()
                    .disabled(
                        teachDraftName.trimmingCharacters(in: .whitespaces).isEmpty
                        || teachDraftSteps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func taughtSkillRow(skill: PaceSkillFile, isDeletable: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 13, weight: .medium))
                    if !isDeletable {
                        Text("built-in")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
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
                    deleteTaughtSkill(skill)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Delete this automation")
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
                    Text("deterministic program")
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
                deleteProgrammedSkill(program)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Delete this programmed automation")
        }
        .padding(.vertical, 10)
    }

    // MARK: - Your-skills data + actions

    private func filteredUserSkills() -> [PaceSkillFile] {
        filterTaughtSkills(userTaughtSkills)
    }

    private func filteredUserPrograms() -> [PaceProgramDefinition] {
        let normalizedQuery = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedQuery.isEmpty else { return userPrograms }
        return userPrograms.filter { program in
            program.name.lowercased().contains(normalizedQuery)
                || program.description.lowercased().contains(normalizedQuery)
                || program.invocationPhrases.contains(where: {
                    $0.lowercased().contains(normalizedQuery)
                })
        }
    }

    private func filteredBundledSkills() -> [PaceSkillFile] {
        filterTaughtSkills(bundledSkills)
    }

    private func filterTaughtSkills(_ skills: [PaceSkillFile]) -> [PaceSkillFile] {
        let normalizedQuery = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedQuery.isEmpty else { return skills }
        return skills.filter { skill in
            skill.name.lowercased().contains(normalizedQuery)
                || skill.description.lowercased().contains(normalizedQuery)
                || (skill.trigger?.lowercased().contains(normalizedQuery) ?? false)
        }
    }

    private func reloadTaughtSkills() {
        userPrograms = PaceUserProgramStore().listValidPrograms()
        let loadedUserSkills = PaceSkillLoader.listUserSkills()
        let userSkillSlugs = Set(loadedUserSkills.map(\.slug))
        userTaughtSkills = loadedUserSkills
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        // Bundled = everything loadAllSkills() sees minus anything the user has
        // taught (a user file with the same slug shadows the bundled one).
        bundledSkills = PaceSkillLoader.loadAllSkills()
            .filter { !userSkillSlugs.contains($0.slug) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
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
            try PaceSkillLoader.save(skill)
            reloadTaughtSkills()
            clearTeachDraft()
            withAnimation { isTeachFormExpanded = false }
        } catch {
            teachFeedbackMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func deleteTaughtSkill(_ skill: PaceSkillFile) {
        try? PaceSkillLoader.deleteUserSkill(slug: skill.slug)
        reloadTaughtSkills()
    }

    private func deleteProgrammedSkill(_ program: PaceProgramDefinition) {
        try? PaceUserProgramStore().delete(identifier: program.identifier)
        reloadTaughtSkills()
    }

    // MARK: - Local skills

    private var localSkillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Built-in actions")
                .font(.system(size: 14, weight: .semibold))
            Text("On-device. No network. Always available.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                ForEach(filteredLocalTools(), id: \.canonicalName) { definition in
                    localSkillRow(definition: definition)
                    Divider().opacity(0.25)
                }
                if filteredLocalTools().isEmpty {
                    Text("No actions match \"\(searchQuery)\".")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private func localSkillRow(definition: PaceLocalToolDefinition) -> some View {
        let isCopiedRecently = lastCopiedExampleUtteranceSlug == definition.canonicalName
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(definition.canonicalName)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
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
                Text(definition.riskLevel.displayName)
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
                .help(isCopiedRecently ? "Copied" : "Copy example utterance")
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
        let normalizedQuery = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedQuery.isEmpty else {
            return PaceToolRegistry.localTools
        }
        return PaceToolRegistry.localTools.filter { definition in
            definition.canonicalName.lowercased().contains(normalizedQuery)
                || definition.description.lowercased().contains(normalizedQuery)
                || definition.exampleUtterance.lowercased().contains(normalizedQuery)
                || definition.aliases.contains { alias in alias.lowercased().contains(normalizedQuery) }
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
            Text("MCP servers")
                .font(.system(size: 14, weight: .semibold))
            Text("Configured at ~/.config/pace/mcp-servers.json. Each server adds external actions through the Model Context Protocol.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                ForEach(filteredMCPServerNames(), id: \.self) { serverName in
                    mcpServerRow(serverName: serverName)
                    Divider().opacity(0.25)
                }
                if filteredMCPServerNames().isEmpty {
                    Text("No MCP servers match \"\(searchQuery)\".")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private func mcpServerRow(serverName: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(serverName)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                Text("MCP server registered in ~/.config/pace/mcp-servers.json. Pace calls it via stdio JSON-RPC when the planner emits an mcp tool call targeting this server.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(PaceToolRiskLevel.externalIntegration.displayName)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.18))
                .clipShape(Capsule())
        }
        .padding(.vertical, 10)
    }

    private func filteredMCPServerNames() -> [String] {
        let normalizedQuery = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedQuery.isEmpty else { return configuredMCPServerNames }
        return configuredMCPServerNames.filter { serverName in
            serverName.lowercased().contains(normalizedQuery)
        }
    }
}
