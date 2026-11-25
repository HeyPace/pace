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

}

struct PaceChatPowerCatalogAnswer: View {
    let catalog: PaceChatPowerCatalog
    let openCategory: (PaceChatPowerCatalog.Category?) -> Void

    var body: some View {
        let counts = Dictionary(grouping: catalog.entries, by: \.category).mapValues(\.count)
        let builtIn = counts[.builtIn, default: 0]
        let saved = counts[.saved, default: 0]
        let total = builtIn + saved
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(total) \(total == 1 ? "power" : "powers")")
                    .font(.system(size: 19, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    openCategory(nil)
                } label: {
                    Label("Search all", systemImage: "magnifyingglass")
                        .font(DS.Typography.calloutStrong)
                        .padding(.horizontal, 5)
                        .frame(minHeight: 28)
                }
                .buttonStyle(.plain)
                .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
                .pointerCursor()
                .accessibilityLabel("Search all powers and tools")
            }
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

enum PacePowerBrowserResult: Identifiable {
    case power(PaceChatPowerCatalog.Entry)
    case connection(PacePowerConnection)
    case builtInAction(PaceLocalToolDefinition)

    var id: String {
        switch self {
        case .power(let entry): "power/" + entry.id
        case .connection(let connection): "connection/" + connection.id
        case .builtInAction(let definition): "action/" + definition.canonicalName
        }
    }

    var name: String {
        switch self {
        case .power(let entry): entry.name
        case .connection(let connection): connection.name
        case .builtInAction(let definition):
            PaceChatTranscriptModel.toolDisplayName(fromRawToolName: definition.canonicalName)
        }
    }

    var groupTitle: String {
        switch self {
        case .power(let entry): entry.category.title
        case .connection: "Connected apps & tools"
        case .builtInAction: "Built-in action"
        }
    }

    var isDisabled: Bool {
        if case .power(let entry) = self { return !entry.isEnabled }
        return false
    }

    func searchRank(for search: String) -> Int? {
        guard !search.isEmpty else { return 0 }
        let identifiers: [String]
        let descriptions: [String]
        switch self {
        case .power(let entry):
            identifiers = [entry.name]
            descriptions = [entry.summary, entry.source, groupTitle]
        case .connection(let connection):
            identifiers = [connection.name, connection.id] + connection.searchTerms
            descriptions = [connection.source, connection.summary, groupTitle]
        case .builtInAction(let definition):
            identifiers = [name] + definition.allNames
            descriptions = [definition.description, definition.exampleUtterance, groupTitle]
        }
        if identifiers.contains(where: { $0.localizedCaseInsensitiveCompare(search) == .orderedSame }) { return 0 }
        if identifiers.contains(where: { $0.localizedCaseInsensitiveContains(search) }) { return 1 }
        let searchable = (identifiers + descriptions).joined(separator: " ")
        let terms = search.split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { searchable.localizedCaseInsensitiveContains(String($0)) } ? 2 : nil
    }
}

struct PaceChatPowerCatalogBrowser: View {
    let catalog: PaceChatPowerCatalog
    let returnTitle: String
    let goBack: () -> Void
    let openConnection: (PacePowerConnection) -> Void
    let useConnection: (PacePowerConnection) -> Void
    let useExample: (String) -> Void
    let performAction: (PaceChatPowerCatalog.Entry, PaceChatPowerCatalog.Action) -> Void

    @State private var connections: [PacePowerConnection] = []
    @State private var category: PaceChatPowerCatalog.Category?
    @State private var query = ""
    @State private var inspectedID: String?
    @State private var highlightedID: String?
    private enum FocusTarget: Hashable { case search, results, back }
    @FocusState private var focus: FocusTarget?

    init(
        catalog: PaceChatPowerCatalog, initialCategory: PaceChatPowerCatalog.Category?,
        returnTitle: String, goBack: @escaping () -> Void,
        openConnection: @escaping (PacePowerConnection) -> Void,
        useConnection: @escaping (PacePowerConnection) -> Void,
        useExample: @escaping (String) -> Void,
        performAction: @escaping (PaceChatPowerCatalog.Entry, PaceChatPowerCatalog.Action) -> Void
    ) {
        self.catalog = catalog
        self.returnTitle = returnTitle
        self.goBack = goBack
        self.openConnection = openConnection
        self.useConnection = useConnection
        self.useExample = useExample
        self.performAction = performAction
        _category = State(initialValue: initialCategory)
    }

    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var activeScope: PaceChatPowerCatalog.Category? { search.isEmpty ? category : nil }

    private var filteredEntries: [PacePowerBrowserResult] {
        let powers = catalog.entries.filter { activeScope == nil || $0.category == activeScope }
        let results =
            powers.map(PacePowerBrowserResult.power)
            + (activeScope == nil ? connections.map(PacePowerBrowserResult.connection) : [])
            + (search.isEmpty ? [] : PaceToolRegistry.localTools.map(PacePowerBrowserResult.builtInAction))
        return results.compactMap { result in
            result.searchRank(for: search).map { (result: result, rank: $0) }
        }.sorted { first, second in
            if first.rank != second.rank { return first.rank < second.rank }
            let comparison = first.result.name.localizedStandardCompare(second.result.name)
            return comparison == .orderedSame ? first.result.id < second.result.id : comparison == .orderedAscending
        }.map(\.result)
    }

    var body: some View {
        let results = filteredEntries
        return VStack(alignment: .leading, spacing: 10) {
            let inspected = results.first { $0.id == inspectedID }
            Button(action: back) {
                Label(
                    inspected == nil ? returnTitle : (activeScope?.title ?? "Powers and tools"),
                    systemImage: "chevron.left"
                )
                .font(DS.Typography.calloutStrong)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .back)
            .keyboardShortcut(.cancelAction)
            .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
            .pointerCursor()
            .foregroundStyle(DS.Colors.textSecondary)
            if case .power(let inspected) = inspected {
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
            } else if case .builtInAction(let definition) = inspected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(PaceChatTranscriptModel.toolDisplayName(fromRawToolName: definition.canonicalName))
                            .font(.system(size: 24, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(definition.description)
                            .font(DS.Typography.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("“\(definition.exampleUtterance)”")
                            .font(DS.Typography.body)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Button {
                            useExample(definition.exampleUtterance)
                        } label: {
                            Label("Use example", systemImage: "text.bubble")
                                .font(DS.Typography.calloutStrong)
                        }
                        .buttonStyle(.bordered)
                        .pointerCursor()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if case .connection(let connection) = inspected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(connection.name)
                            .font(.system(size: 24, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(connection.summary).font(DS.Typography.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(connection.status).font(DS.Typography.calloutStrong)
                            .foregroundStyle(DS.Colors.textSecondary)
                        Button {
                            useConnection(connection)
                        } label: {
                            Label("Use in chat", systemImage: "text.bubble")
                                .font(DS.Typography.calloutStrong)
                        }
                        .buttonStyle(.bordered)
                        .pointerCursor()
                        PaceConnectionTestView(serverName: connection.id)
                            .id(connection.id)
                        Button {
                            openConnection(connection)
                        } label: {
                            Label("Connection settings", systemImage: "gearshape")
                                .font(DS.Typography.calloutStrong)
                        }
                        .buttonStyle(.bordered)
                        .pointerCursor()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Powers and tools")
                    .font(.system(size: 27, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                categoryTabs
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField("Search powers and tools", text: $query)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .search)
                        .onKeyPress(.downArrow) {
                            guard let first = results.first else { return .ignored }
                            highlightedID = first.id
                            focus = .results
                            return .handled
                        }
                        .onSubmit {
                            if let first = results.first { inspect(first) }
                        }
                }
                .font(DS.Typography.body)
                .padding(.horizontal, 9)
                .frame(minHeight: 32)
                .background(DS.Colors.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
                if results.isEmpty {
                    Text(
                        search.isEmpty
                            ? (category.map { "No \($0.title.lowercased()) yet." } ?? "No powers or connections yet.")
                            : "No powers or tools match “\(search)”."
                    )
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .padding(.vertical, 8)
                } else {
                    ScrollViewReader { listProxy in
                        List(selection: $highlightedID) {
                            ForEach(results) { entry in
                                Button {
                                    inspect(entry)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(entry.name).font(DS.Typography.body)
                                        Spacer()
                                        if activeScope == nil {
                                            Text(entry.groupTitle)
                                                .font(DS.Typography.caption)
                                                .foregroundStyle(DS.Colors.textSecondary)
                                                .lineLimit(1)
                                        }
                                        if entry.isDisabled {
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
                            guard let entry = results.first(where: { $0.id == highlightedID }) else {
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
        .task {
            // The chat field releases its AppKit field editor as the new content is mounted.
            await Task.yield()
            guard !Task.isCancelled else { return }
            connections = PacePowerConnection.configured()
            focus = .search
        }
        .onChange(of: query) { highlightedID = nil }
    }

    private var categoryTabs: some View {
        let scopes: [PaceChatPowerCatalog.Category?] = [nil] + PaceChatPowerCatalog.Category.browserOrder.map { $0 }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(scopes, id: \.self) { scope in
                    Button {
                        selectCategory(scope)
                    } label: {
                        Text(scope?.tabTitle ?? "All")
                            .font(DS.Typography.calloutStrong)
                            .foregroundStyle(activeScope == scope ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                            .padding(.vertical, 6)
                            .overlay(alignment: .bottom) {
                                if scope == activeScope { Capsule().fill(DS.Colors.textPrimary).frame(height: 2) }
                            }
                    }
                    .buttonStyle(.plain)
                    .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
                    .pointerCursor()
                    .accessibilityAddTraits(activeScope == scope ? .isSelected : [])
                }
            }
            .fixedSize()
            Picker("Category", selection: Binding(get: { activeScope }, set: selectCategory)) {
                ForEach(scopes, id: \.self) { scope in
                    Text(scope?.title ?? "All powers and tools").tag(scope)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func selectCategory(_ next: PaceChatPowerCatalog.Category?) {
        guard activeScope != next else { return }
        category = next
        focus = .search
        query = ""
        highlightedID = nil
    }

    private func inspect(_ entry: PacePowerBrowserResult) {
        focus = .back
        inspectedID = entry.id
        highlightedID = entry.id
    }

    private func back() {
        if let inspectedID, filteredEntries.contains(where: { $0.id == inspectedID }) {
            self.inspectedID = nil
        } else {
            goBack()
        }
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
    let catalog: PaceChatPowerCatalog?
    let category: PaceChatPowerCatalog.Category?
}

struct PacePowerSearchButton: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Label("Powers", systemImage: "magnifyingglass")
                .font(DS.Typography.calloutStrong)
                .padding(.horizontal, 5)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.Colors.textSecondary)
        .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
        .pointerCursor()
        .accessibilityLabel("Search powers and tools")
        .help("Search powers, workflows and connected tools")
    }
}

struct PaceCurrentPowerBrowser: View {
    let location: PacePowerBrowserLocation
    let companionManager: CompanionManager
    let returnTitle: String
    let goBack: () -> Void
    let useConnection: (PacePowerConnection) -> Void
    let useExample: (String) -> Void
    let performAction: (PaceChatPowerCatalog.Entry, PaceChatPowerCatalog.Action) -> Void

    @State private var latestCatalog: PaceChatPowerCatalog?
    @State private var loadingShortcuts = false

    var body: some View {
        VStack(spacing: 0) {
            if let catalog = latestCatalog ?? location.catalog {
                PaceChatPowerCatalogBrowser(
                    catalog: catalog, initialCategory: location.category,
                    returnTitle: returnTitle, goBack: goBack,
                    openConnection: companionManager.openPowerConnection,
                    useConnection: useConnection, useExample: useExample, performAction: performAction)
                if loadingShortcuts {
                    Text("Checking Apple Shortcuts…")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            } else {
                ProgressView("Loading powers…").controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let needsShortcuts = PaceShortcutsAutomationProvider.shared.cachedCatalogIfFresh() == nil
            loadingShortcuts = needsShortcuts
            if location.catalog == nil || !needsShortcuts {
                await loadCatalog(refreshShortcuts: false)
            }
            if needsShortcuts && !Task.isCancelled { await loadCatalog(refreshShortcuts: true) }
            loadingShortcuts = false
        }
    }

    private func loadCatalog(refreshShortcuts: Bool) async {
        let discovered = await companionManager.discoverAutomationCatalog(
            refreshShortcutCatalog: refreshShortcuts, warmShortcutCache: false)
        guard !Task.isCancelled else { return }
        let powers = companionManager.managedPowerStore.list(catalog: discovered.catalog)
        latestCatalog = PaceChatPowerCatalog(entries: powers.map(PaceChatPowerCatalog.Entry.init(power:)))
    }
}
