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

    // "Teach a skill" form draft state (the typed sibling of the voice path).
    @State private var isTeachFormExpanded: Bool = false
    @State private var teachDraftName: String = ""
    @State private var teachDraftSteps: String = ""
    @State private var teachDraftTrigger: String = ""
    @State private var teachFeedbackMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    yourSkillsSection
                    localSkillsSection
                    if !configuredMCPServerNames.isEmpty {
                        mcpSkillsSection
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            Text("Skills")
                .font(.system(size: 22, weight: .semibold))
            Text("Everything Pace can run — including skills you teach it. Teach a skill by describing it here or by saying \u{201C}teach a skill\u{2026}\u{201D} out loud. Local skills are built-in tools; MCP servers add more via stdio bridges configured at ~/.config/pace/mcp-servers.json.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private var searchField: some View {
        TextField("Search skills…", text: $searchQuery)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 24)
    }

    // MARK: - Your skills (taught .skill.md skills)

    private var yourSkillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your skills")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Multi-step tasks you taught Pace. Say \u{201C}run <name>\u{201D} to execute one.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(isTeachFormExpanded ? "Cancel" : "Teach a skill") {
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
                ForEach(filteredUserSkills(), id: \.slug) { skill in
                    taughtSkillRow(skill: skill, isDeletable: true)
                    Divider().opacity(0.25)
                }
                if filteredUserSkills().isEmpty && !isTeachFormExpanded {
                    Text(searchQuery.isEmpty
                         ? "No taught skills yet. Tap \u{201C}Teach a skill\u{201D} or say \u{201C}teach a skill\u{2026}\u{201D} out loud."
                         : "No taught skills match \u{201C}\(searchQuery)\u{201D}.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                }
            }

            if !filteredBundledSkills().isEmpty {
                Text("Built-in skills")
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
            TextField("Skill name (e.g. Start My Day)", text: $teachDraftName)
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
                Button("Save skill") { saveTaughtSkillFromForm() }
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
                .help("Delete this skill")
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Your-skills data + actions

    private func filteredUserSkills() -> [PaceSkillFile] {
        filterTaughtSkills(userTaughtSkills)
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

    // MARK: - Local skills

    private var localSkillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local skills")
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
                    Text("No skills match \"\(searchQuery)\".")
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
            Text("Configured at ~/.config/pace/mcp-servers.json. Each server adds external skills via the Model Context Protocol.")
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
