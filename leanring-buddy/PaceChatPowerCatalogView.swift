import SwiftUI

extension PaceChatPowerCatalog.Category {
    fileprivate static var browserOrder: [Self] { [.builtIn, .saved, .installed] }

    fileprivate var tabTitle: String {
        switch self {
        case .builtIn: "Built-in"
        case .saved: "Saved"
        case .installed: "Workflows"
        }
    }

    fileprivate var searchPlaceholder: String {
        switch self {
        case .builtIn: "Find a built-in power"
        case .saved: "Find a saved power"
        case .installed: "Find an installed workflow"
        }
    }
}

struct PaceChatPowerCatalogAnswer: View {
    let catalog: PaceChatPowerCatalog
    let openCategory: (PaceChatPowerCatalog.Category) -> Void

    var body: some View {
        let counts = Dictionary(grouping: catalog.entries, by: \.category).mapValues(\.count)
        let builtIn = counts[.builtIn, default: 0]
        let saved = counts[.saved, default: 0]
        let workflows = counts[.installed, default: 0]
        let total = builtIn + saved
        VStack(alignment: .leading, spacing: 7) {
            Text("You have \(total) \(total == 1 ? "power" : "powers").")
                .font(.system(size: 21, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(
                "\(builtIn) built-in and \(saved) saved. You also have \(workflows) installed \(workflows == 1 ? "workflow" : "workflows")."
            )
            .font(DS.Typography.body)
            .foregroundStyle(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(PaceChatPowerCatalog.Category.browserOrder, id: \.self) { category in
                    Button {
                        openCategory(category)
                    } label: {
                        HStack(spacing: 8) {
                            Text(category.title)
                                .font(DS.Typography.bodyStrong)
                            Spacer()
                            Text("\(counts[category, default: 0])")
                                .monospacedDigit()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(DS.Colors.textSecondary)
                        .padding(.horizontal, 11)
                        .frame(minHeight: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
                    .pointerCursor()
                    if category != .installed {
                        Divider().padding(.horizontal, 11)
                    }
                }
            }
            .background(DS.Colors.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .padding(.top, 4)
        }
        .foregroundStyle(DS.Colors.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PaceChatPowerCatalogBrowser: View {
    let catalog: PaceChatPowerCatalog
    let returnTitle: String
    let goBack: () -> Void
    let performAction: (PaceChatPowerCatalog.Entry, PaceChatPowerCatalog.Action) -> Void

    @State private var category: PaceChatPowerCatalog.Category
    @State private var query = ""
    @State private var inspectedID: String?
    @State private var highlightedID: String?
    private enum FocusTarget: Hashable { case search, results, back }
    @FocusState private var focus: FocusTarget?

    init(
        catalog: PaceChatPowerCatalog, initialCategory: PaceChatPowerCatalog.Category,
        returnTitle: String, goBack: @escaping () -> Void,
        performAction: @escaping (PaceChatPowerCatalog.Entry, PaceChatPowerCatalog.Action) -> Void
    ) {
        self.catalog = catalog
        self.returnTitle = returnTitle
        self.goBack = goBack
        self.performAction = performAction
        _category = State(initialValue: initialCategory)
    }

    private var filteredEntries: [PaceChatPowerCatalog.Entry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.entries.filter { entry in
            entry.category == category
                && (search.isEmpty || entry.name.localizedCaseInsensitiveContains(search)
                    || entry.summary.localizedCaseInsensitiveContains(search)
                    || entry.source.localizedCaseInsensitiveContains(search))
        }
        .sorted { first, second in
            let comparison = first.name.localizedStandardCompare(second.name)
            return comparison == .orderedSame ? first.id < second.id : comparison == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let inspected = catalog.entries.first { $0.id == inspectedID && $0.category == category }
            Button(action: back) {
                Label(inspected == nil ? returnTitle : category.title, systemImage: "chevron.left")
                    .font(DS.Typography.calloutStrong)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .back)
            .keyboardShortcut(.cancelAction)
            .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
            .pointerCursor()
            .foregroundStyle(DS.Colors.textSecondary)
            if let inspected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(inspected.name)
                            .font(.system(size: 24, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(inspected.summary)
                            .font(DS.Typography.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if !inspected.source.isEmpty {
                            Text(inspected.source)
                                .font(DS.Typography.callout)
                                .foregroundStyle(DS.Colors.textSecondary)
                        }
                        if !inspected.isEnabled {
                            Text("Disabled").font(DS.Typography.calloutStrong)
                        }
                        HStack(spacing: 12) {
                            if inspected.actions.contains(.show) {
                                actionButton("Show details", icon: "list.bullet", entry: inspected, action: .show)
                            }
                            if inspected.isEnabled && inspected.actions.contains(.run) {
                                actionButton("Run", icon: "play.fill", entry: inspected, action: .run)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Powers")
                    .font(.system(size: 27, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                categoryTabs
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField(category.searchPlaceholder, text: $query)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .search)
                        .onKeyPress(.downArrow) {
                            guard let first = filteredEntries.first else { return .ignored }
                            highlightedID = first.id
                            focus = .results
                            return .handled
                        }
                        .onSubmit {
                            if let first = filteredEntries.first { inspect(first) }
                        }
                }
                .font(DS.Typography.body)
                .padding(.horizontal, 9)
                .frame(minHeight: 32)
                .background(DS.Colors.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
                if filteredEntries.isEmpty {
                    Text(query.isEmpty ? "No items in this category." : "No matches for “\(query)”.")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .padding(.vertical, 8)
                } else {
                    ScrollViewReader { listProxy in
                        List(selection: $highlightedID) {
                            ForEach(filteredEntries) { entry in
                                Button {
                                    inspect(entry)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(entry.name).font(DS.Typography.body)
                                        Spacer()
                                        if !entry.isEnabled {
                                            Text("Disabled").font(DS.Typography.caption)
                                        }
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(DS.Colors.textTertiary)
                                            .accessibilityHidden(true)
                                    }
                                    .frame(minHeight: 32)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
                                .pointerCursor()
                                .tag(entry.id)
                                .id(entry.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 1, bottom: 0, trailing: 1))
                            }
                        }
                        .listStyle(.plain)
                        .focused($focus, equals: .results)
                        .scrollContentBackground(.hidden)
                        .onKeyPress(.return) {
                            guard let entry = filteredEntries.first(where: { $0.id == highlightedID }) else {
                                return .ignored
                            }
                            inspect(entry)
                            return .handled
                        }
                        .task {
                            if let highlightedID {
                                listProxy.scrollTo(highlightedID, anchor: .center)
                                focus = .results
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(DS.Colors.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focus = .search }
        .onChange(of: query) { highlightedID = nil }
    }

    private var categoryTabs: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                ForEach(PaceChatPowerCatalog.Category.browserOrder, id: \.self) { item in
                    let count = catalog.entries.filter { $0.category == item }.count
                    Button {
                        selectCategory(item)
                    } label: {
                        Text("\(item.tabTitle) · \(count)")
                            .font(DS.Typography.calloutStrong)
                            .foregroundStyle(category == item ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                            .padding(.vertical, 6)
                            .overlay(alignment: .bottom) {
                                if item == category { Capsule().fill(DS.Colors.textPrimary).frame(height: 2) }
                            }
                    }
                    .buttonStyle(.plain)
                    .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
                    .pointerCursor()
                    .accessibilityAddTraits(category == item ? .isSelected : [])
                }
            }
            .fixedSize()
            Picker("Category", selection: Binding(get: { category }, set: selectCategory)) {
                ForEach(PaceChatPowerCatalog.Category.browserOrder, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func selectCategory(_ next: PaceChatPowerCatalog.Category) {
        guard category != next else { return }
        category = next
        focus = .search
        query = ""
        highlightedID = nil
    }

    private func inspect(_ entry: PaceChatPowerCatalog.Entry) {
        focus = .back
        inspectedID = entry.id
        highlightedID = entry.id
    }

    private func back() {
        if inspectedID != nil { inspectedID = nil } else { goBack() }
    }

    private func actionButton(
        _ label: String, icon: String, entry: PaceChatPowerCatalog.Entry, action: PaceChatPowerCatalog.Action
    ) -> some View {
        Button {
            performAction(entry, action)
        } label: {
            Label(label, systemImage: icon).font(DS.Typography.calloutStrong)
        }
        .buttonStyle(.bordered)
        .pointerCursor()
    }
}

extension PaceChatSession {
    func historicalPowerCount(for source: PaceChatMessage?) -> String? {
        guard let source, source.role == .pace, source.powerCatalog == nil,
            source.body.hasSuffix("Say show power followed by an exact name for its steps and controls."),
            let counts = source.body.components(separatedBy: "\nBuilt-in powers: ").first,
            counts.count < 128, counts.contains("built-in powers, "),
            let turnID = source.turnIdentifier ?? source.persistedTurnIdentifier,
            messages.contains(where: { message in
                message.role == .user && (message.turnIdentifier ?? message.persistedTurnIdentifier) == turnID
                    && PacePowerCommandParser.parse(message.body) == .list
            })
        else { return nil }
        return counts
    }
}

struct PacePowerBrowserLocation {
    let catalog: PaceChatPowerCatalog
    let category: PaceChatPowerCatalog.Category
}
