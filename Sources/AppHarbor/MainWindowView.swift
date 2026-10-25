import AppHarborCore
import AppKit
import SwiftUI

struct MainWindowView: View {
    @Bindable var model: LibraryModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var visibleManagers: [ManagerInstance] {
        model.managers.filter { $0.presence != .absent }.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $model.destination) {
                Section {
                    destinationRow("All Software", symbol: "shippingbox", count: model.installations.count, destination: .allSoftware)
                    destinationRow("Applications", symbol: "square.grid.2x2", count: model.installations.filter { $0.kind == .appBundle || $0.kind == .cask }.count, destination: .applications)
                    destinationRow("Command Line", symbol: "terminal", count: model.installations.filter { $0.kind != .appBundle && $0.kind != .cask }.count, destination: .commandLine)
                    destinationRow("Updates", symbol: "arrow.triangle.2.circlepath", count: model.snapshot?.updateChecks.filter { $0.status == .updateAvailable }.count, destination: .updates)
                    destinationRow("Activity", symbol: "list.bullet.rectangle", count: model.taskRecords.count, destination: .activity)
                }
                Section("Sources") {
                    if visibleManagers.isEmpty {
                        Label("No supported sources detected", systemImage: "circle.dashed")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visibleManagers) { manager in
                        Label {
                            HStack {
                                Text(managerLabel(manager, among: visibleManagers))
                                if manager.presence != .present { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).help(presenceName(manager.presence)) }
                                Spacer(minLength: 8)
                                Text("\(model.installations.filter { $0.identity.managerID == manager.id }.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        } icon: { Image(systemName: sourceSymbol(manager.kind)) }
                            .tag(SidebarDestination.source(manager.id))
                            .accessibilityLabel("\(sourceName(manager.kind)), \(manager.scope.displayName)")
                    }
                }
                Section {
                    Label("Manage Sources", systemImage: "slider.horizontal.3")
                        .tag(SidebarDestination.manageSources)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 270)
            .safeAreaInset(edge: .bottom) {
                if let snapshot = model.snapshot {
                    HStack(spacing: 5) {
                        Image(systemName: model.coverage.contains { $0.state != .complete } ? "exclamationmark.circle" : "checkmark.circle")
                        Text("\(snapshot.installations.count) installations · \(visibleManagers.filter { $0.presence == .present }.count) sources")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
        } detail: {
            detailContent
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search software")
        .toolbar {
            if model.destination != .manageSources && model.destination != .activity && model.destination != .updates {
                ToolbarItem(placement: .principal) {
                    Picker("Library View", selection: $model.libraryViewMode) {
                        Label("List", systemImage: "list.bullet").tag(LibraryViewMode.list)
                        Label("Grid", systemImage: "square.grid.2x2").tag(LibraryViewMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Choose list or grid view")
                }
            }
            ToolbarItemGroup {
                Button {
                    if model.isRefreshing { model.cancelRefresh() }
                    else { Task { await model.refresh() } }
                } label: {
                    Label(model.isRefreshing ? "Cancel Scan" : "Refresh Inventory", systemImage: model.isRefreshing ? "stop.circle" : "arrow.clockwise")
                }
                .help(model.isRefreshing ? "Cancel local inventory scan" : "Refresh local installation inventory")
                if model.isRefreshing { ProgressView().controlSize(.small).help("Scanning installed software") }
            }
            ToolbarItem {
                Button { model.isInspectorPresented.toggle() } label: {
                    Label("Show Details", systemImage: "sidebar.right")
                }
                .help(model.isInspectorPresented ? "Hide Details" : "Show Details")
                .disabled(model.selectedInstallation == nil)
            }
        }
        .sheet(item: $model.planDecision, onDismiss: model.planDecisionSheetDidDismiss) { decision in
            PlanDecisionSheet(decision: decision, mode: model.planSheetMode,
                              reviewContext: model.mcpReviewContext,
                              isExecuting: model.isExecutingOperation, isCancelling: model.isCancellingOperation,
                              onConfirm: { plan in Task { await model.execute(plan) } },
                              onCancelOperation: model.cancelOperation,
                              onClose: { model.planDecision = nil })
                .onAppear { model.planDecisionSheetDidPresent() }
        }
        .onChange(of: model.destination) { _, value in
            if case let .source(id) = value { model.sourceFilter = id } else { model.sourceFilter = nil }
            model.pruneSelection()
        }
        .onChange(of: model.visibleInstallations.map(\.identity)) { _, identities in
            model.pruneSelection(to: Set(identities))
        }
    }

    @ViewBuilder private var detailContent: some View {
        switch model.destination {
        case .manageSources: SourcesView(model: model)
        case .updates: UpdatesView(model: model)
        case .activity: ActivityView(model: model)
        default: LibraryView(model: model)
        }
    }

    private func destinationRow(_ title: String, symbol: String, count: Int?, destination: SidebarDestination) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                if let count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
        } icon: { Image(systemName: symbol) }
            .tag(destination)
    }
}

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @State private var sortOrder = [KeyPathComparator<Installation>(\.displayName)]

    private var sortedItems: [Installation] { model.visibleInstallations.sorted(using: sortOrder) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("Type", selection: $model.kindFilter) {
                    Text("All Types").tag(ItemKindFilter.all)
                    Text("Applications").tag(ItemKindFilter.applications)
                    Text("Command Line").tag(ItemKindFilter.commandLine)
                }
                .pickerStyle(.menu)
                .fixedSize()
                Picker("Source", selection: $model.sourceFilter) {
                    Text("All Sources").tag(String?.none)
                    ForEach(model.managers.filter { $0.presence != .absent }) { manager in
                        Text(managerLabel(manager, among: model.managers)).help(manager.scope.displayName).tag(String?.some(manager.id))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
                Text("\(model.visibleInstallations.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) { Divider() }

            if model.snapshot == nil && model.isRefreshing {
                LoadingInventoryView()
            } else if let error = model.refreshError, model.snapshot == nil {
                ContentUnavailableView("Inventory unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.snapshot == nil {
                ContentUnavailableView {
                    Label("Scanning Software", systemImage: "arrow.triangle.2.circlepath")
                } description: {
                    Text("AppHarbor checks supported local sources. It does not search every executable on the Mac.")
                } actions: {
                    Button("Refresh Inventory") { Task { await model.refresh() } }
                }
            } else if sortedItems.isEmpty && !model.searchText.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else if sortedItems.isEmpty && model.installations.isEmpty {
                ContentUnavailableView("No Installations Found", systemImage: "shippingbox", description: Text("The checked application folders and detected manager scopes returned no installations. Add a scan location in Settings or review Sources for coverage details."))
            } else if sortedItems.isEmpty {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No installations match the current type and source filters.")
                } actions: {
                    Button("Clear Filters") { model.kindFilter = .all; model.sourceFilter = nil }
                }
            } else {
                Group {
                    if model.libraryViewMode == .list {
                        Table(sortedItems, selection: $model.selection, sortOrder: $sortOrder) {
                            TableColumn("Name", value: \.displayName) { item in
                                HStack(spacing: 8) {
                                    ApplicationIconView(installation: item, size: 20)
                                    Text(item.displayName)
                                        .lineLimit(1)
                                        .help(item.displayName)
                                }
                                .contextMenu { installationMenu(for: item, model: model) }
                            }
                            .width(min: 180, ideal: 280)
                            TableColumn("Source") { item in
                                Text(model.managers.first { $0.id == item.identity.managerID }.map { managerLabel($0, among: model.managers) } ?? "Unknown")
                                    .foregroundStyle(.secondary)
                            }
                            .width(min: 120, ideal: 160)
                            TableColumn("Version") { item in
                                Text(item.version ?? "Unknown")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .width(min: 90, ideal: 110)
                            TableColumn("Kind") { item in Text(kindName(item.kind)).foregroundStyle(.secondary) }
                                .width(min: 100, ideal: 120)
                        }
                    } else {
                        InstallationGrid(model: model, items: sortedItems)
                    }
                }
                .inspector(isPresented: $model.isInspectorPresented) {
                    InstallationInspector(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                }
            }
        }
        .navigationTitle(titleForDestination(model.destination))
        .onChange(of: model.selection) { _, selection in
            model.isInspectorPresented = !selection.isEmpty
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                if let count = model.coverage.first(where: { $0.state != .complete }) {
                    Label(count.warning ?? "Some sources need attention", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

@MainActor private func installationMenu(for item: Installation, model: LibraryModel) -> some View {
    Group {
        Button("How to Remove…") { Task { await model.openRemovalGuide(for: item) } }
            .disabled(model.isExecutingOperation || model.isPreparingPlan || model.planDecision != nil)
        Button("Remove…", role: .destructive) { Task { await model.prepare(.remove, for: item) } }
            .disabled(!model.canChangeConfiguration || !item.removalSupported || item.isProtected || item.ownership != .verified || item.isStale)
    }
}

private struct InstallationGrid: View {
    @Bindable var model: LibraryModel
    let items: [Installation]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedID: InstallationID?
    @State private var anchorID: InstallationID?
    private let spacing: CGFloat = 12
    private let minimumCellWidth: CGFloat = 154

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(minimumCellWidth, geometry.size.width - 24)
            let columnCount = max(1, Int((contentWidth + spacing) / (minimumCellWidth + spacing)))
            let columns = Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: columnCount)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.element.identity) { index, item in
                            installationButton(item, index: index, columnCount: columnCount, proxy: proxy)
                                .id(item.identity)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onChange(of: items.map(\.identity)) { _, identities in
                    if let anchorID, !identities.contains(anchorID) { self.anchorID = nil }
                }
                .onKeyPress(keys: [.init("a")]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    model.selection = Set(items.map(\.identity))
                    return .handled
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Installed software grid")
    }

    private func installationButton(_ item: Installation, index: Int, columnCount: Int, proxy: ScrollViewProxy) -> some View {
        let isSelected = model.selection.contains(item.identity)
        let stateDescription = [item.isStale ? "stale" : nil, item.isProtected ? "protected" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
        return Button {
            select(item, index: index)
        } label: {
            VStack(spacing: 8) {
                ApplicationIconView(installation: item, size: 48)
                    .frame(height: 52)
                Text(item.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .top)
                Text([item.version ?? "Unknown", sourceName(for: item)].joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedID, equals: item.identity)
        .accessibilityLabel("\(item.displayName), version \(item.version ?? "unknown"), \(sourceName(for: item)), \(kindName(item.kind))\(stateDescription.isEmpty ? "" : ", \(stateDescription)")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu { installationMenu(for: item, model: model) }
        .onMoveCommand { direction in moveFocus(from: item, index: index, columnCount: columnCount, direction: direction, proxy: proxy) }
        .help("\(item.displayName) · \(item.version ?? "Unknown")")
    }

    private func sourceName(for item: Installation) -> String {
        guard let manager = model.managers.first(where: { $0.id == item.identity.managerID }) else { return "Unknown source" }
        return managerLabel(manager, among: model.managers)
    }

    private func select(_ item: Installation, index: Int) {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        if modifiers.contains(.command) {
            if model.selection.contains(item.identity) { model.selection.remove(item.identity) }
            else { model.selection.insert(item.identity) }
        } else if modifiers.contains(.shift),
                  let anchor = anchorID ?? items.first(where: { model.selection.contains($0.identity) })?.identity,
                  let anchorIndex = items.firstIndex(where: { $0.identity == anchor }) {
            let lower = min(anchorIndex, index)
            let upper = max(anchorIndex, index)
            model.selection.formUnion(items[lower...upper].map(\.identity))
        } else {
            model.selection = [item.identity]
            anchorID = item.identity
        }
        focusedID = item.identity
    }

    private func moveFocus(from item: Installation, index: Int, columnCount: Int, direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let offset: Int
        switch direction {
        case .left: offset = -1
        case .right: offset = 1
        case .up: offset = -columnCount
        case .down: offset = columnCount
        @unknown default: return
        }
        let next = index + offset
        guard items.indices.contains(next) else { return }
        let destination = items[next]
        focusedID = destination.identity
        model.selection = [destination.identity]
        anchorID = destination.identity
        if reduceMotion {
            proxy.scrollTo(destination.identity, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.12)) {
                proxy.scrollTo(destination.identity, anchor: .center)
            }
        }
    }
}

struct InstallationInspector: View {
    @Bindable var model: LibraryModel
    private var item: Installation? { model.selectedInstallation }
    private var manager: ManagerInstance? { item.flatMap { installation in model.managers.first { $0.id == installation.identity.managerID } } }

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 10) {
                                ApplicationIconView(installation: item, size: 44)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.displayName).font(.title3.weight(.semibold))
                                    Text(item.bundleIdentifier ?? item.identity.nativeID)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        Divider()
                        LabeledContent("Version", value: item.version ?? "Unknown")
                        LabeledContent("Source", value: manager.map { sourceName($0.kind) } ?? "Unknown")
                        LabeledContent("Kind", value: kindName(item.kind))
                        Divider()
                        Label(item.ownership == .verified ? "Matched to source" : "Ownership \(item.ownership.rawValue)", systemImage: item.ownership == .verified ? "checkmark.circle" : "questionmark.circle")
                            .font(.callout)
                        if item.isStale {
                            Label("Stale · refresh before reviewing an action", systemImage: "clock.arrow.circlepath")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Last observed \(item.observedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
            if let manager {
                            Text("\(manager.scope.displayName) · \(manager.scope.canonicalRoot ?? manager.executablePath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        DisclosureGroup("Installation Details") {
                            VStack(alignment: .leading, spacing: 10) {
                                detailField("Package ID", value: item.identity.nativeID)
                                detailField("Manager", value: manager?.executablePath ?? "Unknown")
                                detailField("Location", value: item.canonicalLocation)
                                detailField("Scope", value: item.identity.scopeID)
                                ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, evidence in
                                    detailField(evidence.label, value: evidence.value)
                                }
                            }
                            .padding(.top, 8)
                        }
                        .font(.callout.weight(.medium))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Button("Remove…") { Task { await model.prepare(.remove, for: item) } }
                        .disabled(!item.removalSupported || item.isProtected || item.ownership != .verified || item.isStale)
                        .help(removalDisabledReason(item))
                    Button("How to Remove…") { Task { await model.openRemovalGuide(for: item) } }
                        .buttonStyle(.link)
                    Text(item.removalSupported ? "A command preview opens first." : "Direct removal is unavailable for this installation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background)
        } else {
            ContentUnavailableView("Select an Installation", systemImage: "sidebar.right", description: Text("Choose software to inspect its source, scope and available actions."))
                .frame(minWidth: 260)
        }
    }

    private func detailField(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SourcesView: View {
    @Bindable var model: LibraryModel
    @State private var showDiagnostics = false

    private var rows: [SourceStatusRow] {
        var result = model.managers.filter { showDiagnostics || $0.presence != .absent }.map { manager in
            let inventoryCoverage = coverageForManager(manager, coverage: model.coverage)
            let detectionCoverage = model.coverage.first { $0.sourceName == manager.kind.rawValue && $0.scopeID == "detection" }
            return SourceStatusRow(id: manager.id, name: sourceName(manager.kind), scope: manager.scope.displayName,
                                   inventory: sourceInventoryState(manager, coverage: model.coverage),
                                   removal: manager.presence == .present && manager.removalSupported ? "Supported" : "Guidance",
                                   updates: manager.presence == .present && manager.updateSupported ? "Supported" : "Unknown",
                                   warning: inventoryCoverage?.warning ?? detectionCoverage?.warning
                                    ?? (manager.presence == .present ? nil : manager.evidence.map(\.value).joined(separator: " · ")))
        }
        for coverage in model.coverage where coverage.scopeID == "detection" && (showDiagnostics || coverage.state != .complete) {
            let kind = ManagerKind(rawValue: coverage.sourceName) ?? .other
            let id = "diagnostic-\(coverage.id)"
            guard !result.contains(where: { $0.id == id || $0.name == sourceName(kind) }) else { continue }
            let needsRoot = coverage.warning?.localizedCaseInsensitiveContains("select an explicit") == true
            let inventory: String
            if needsRoot { inventory = "Present · root needed" }
            else {
                switch coverage.state {
                case .complete: inventory = "Absent"
                case .partial: inventory = "Partial"
                case .failed: inventory = "Unavailable"
                }
            }
            result.append(SourceStatusRow(id: id, name: sourceName(kind), scope: "Detection", inventory: inventory, removal: "—", updates: "—", warning: coverage.warning))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Show absent detectors", isOn: $showDiagnostics)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Refresh Sources") { Task { await model.refresh() } }
                    .disabled(model.isRefreshing)
            }
            .padding(12)
            Table(rows) {
                TableColumn("Source") { row in Label(row.name, systemImage: "shippingbox") }.width(min: 120)
                TableColumn("Scope") { row in Text(row.scope) }.width(min: 120, ideal: 220)
                TableColumn("Inventory") { row in Text(row.inventory) }.width(min: 100)
                TableColumn("Removal") { row in Text(row.removal) }.width(min: 100)
                TableColumn("Updates") { row in Text(row.updates) }.width(min: 90)
                TableColumn("Details") { row in Text(row.warning ?? "—").lineLimit(1).foregroundStyle(.secondary).help(row.warning ?? "") }.width(min: 120, ideal: 180)
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No Sources Detected", systemImage: "shippingbox", description: Text("Refresh to check supported package managers and application locations."))
                }
            }
            let attentionCount = model.coverage.filter { $0.state != .complete }.count
            if attentionCount > 0 {
                Label("\(attentionCount) source checks need attention. Review each row’s Details.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .navigationTitle("Sources")
    }
}

private func sourceInventoryState(_ manager: ManagerInstance, coverage: [CoverageSnapshot]) -> String {
    if manager.presence != .present { return presenceName(manager.presence) }
    guard let state = coverageForManager(manager, coverage: coverage)?.state else { return "Not scanned" }
    switch state {
    case .complete: return "Available"
    case .partial: return "Partial"
    case .failed: return "Unavailable"
    }
}

func coverageForManager(_ manager: ManagerInstance, coverage: [CoverageSnapshot]) -> CoverageSnapshot? {
    coverage.first { $0.id == manager.id }
        ?? coverage.first { $0.sourceName == manager.kind.rawValue && $0.scopeID == manager.scope.id }
}

private struct SourceStatusRow: Identifiable {
    let id: String
    let name: String
    let scope: String
    let inventory: String
    let removal: String
    let updates: String
    let warning: String?
}

struct ActivityView: View {
    @Bindable var model: LibraryModel
    var body: some View {
        if model.taskRecords.isEmpty {
            ContentUnavailableView("No Activity Yet", systemImage: "list.bullet.rectangle", description: Text("Reviewed removals and updates will appear here with their verification outcome."))
                .navigationTitle("Activity")
        } else {
            Table(model.taskRecords) {
                TableColumn("Operation") { record in Text(record.operation.rawValue.capitalized) }
                TableColumn("Installation") { record in Text(model.installations.first { $0.identity == record.installationID }?.displayName ?? record.installationID.nativeID) }
                TableColumn("Status") { record in Label(taskStateName(record), systemImage: taskSymbol(record.state)) }
                TableColumn("Result") { record in Text(record.redactedSummary).lineLimit(2).foregroundStyle(.secondary) }
            }
            .navigationTitle("Activity")
        }
    }
}

private struct LoadingInventoryView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView("Scanning supported sources…")
            Text("Results can appear partially while a source is still checking.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


struct UpdatesView: View {
    @Bindable var model: LibraryModel
    private var candidates: [Installation] { model.visibleInstallations.filter(\.updateSupported).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Check each supported installation explicitly. AppHarbor does not check in the background.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Check Selected") {
                    guard let selected = model.selectedInstallation else { return }
                    Task { await model.checkUpdate(for: selected) }
                }
                .disabled(model.selectedInstallation == nil || model.selectedInstallation?.updateSupported != true || model.selectedInstallation.map { model.checkingUpdateIDs.contains($0.identity) } == true)
            }
            .padding(12)
            Table(candidates, selection: $model.selection) {
                TableColumn("Name") { item in Text(item.displayName).lineLimit(1) }.width(min: 140, ideal: 220)
                TableColumn("Source") { item in Text(model.managers.first { $0.id == item.identity.managerID }.map { managerLabel($0, among: model.managers) } ?? "Unknown").foregroundStyle(.secondary) }.width(min: 110)
                TableColumn("Current") { item in Text(item.version ?? "Unknown").font(.system(.body, design: .monospaced)) }.width(min: 90)
                TableColumn("Available") { item in Text(model.snapshot?.updateChecks.first { $0.installationID == item.identity }?.availableVersion ?? "—").font(.system(.body, design: .monospaced)) }.width(min: 90)
                TableColumn("Status") { item in
                    let result = model.snapshot?.updateChecks.first { $0.installationID == item.identity }
                    Label(updateStatusName(result?.status), systemImage: updateStatusSymbol(result?.status))
                        .foregroundStyle(result?.status == .updateAvailable ? Color.accentColor : Color.secondary)
                }.width(min: 120)
                TableColumn("Last Checked") { item in
                    let result = model.snapshot?.updateChecks.first { $0.installationID == item.identity }
                    Text(result?.checkedAt.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                        .font(.caption).foregroundStyle(.secondary)
                }.width(min: 130)
                TableColumn("Action") { item in
                    let result = model.snapshot?.updateChecks.first { $0.installationID == item.identity }
                    if result?.status == .updateAvailable {
                        Button("Review Update…") { Task { await model.prepare(.update, for: item) } }
                    } else {
                        Button(model.checkingUpdateIDs.contains(item.identity) ? "Checking…" : "Check") {
                            Task { await model.checkUpdate(for: item) }
                        }
                        .disabled(model.checkingUpdateIDs.contains(item.identity))
                    }
                }.width(min: 100)
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView("No Update Checks Available", systemImage: "arrow.triangle.2.circlepath", description: Text("Detected sources do not currently provide a validated per-installation update check. Their update status remains unknown."))
                }
            }
            if let failed = model.snapshot?.updateChecks.first(where: { $0.status == .failed || $0.status == .unknown }) {
                Text(failed.explanation ?? "The update status is unknown. Check source availability and try again.")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .navigationTitle("Updates")
    }
}

private func updateStatusName(_ status: UpdateStatus?) -> String {
    switch status {
    case .updateAvailable: "Update Available"
    case .upToDate: "Up to Date"
    case .unknown: "Unknown"
    case .failed: "Check Failed"
    case .unsupported: "Unsupported"
    case nil: "Not Checked"
    }
}

private func updateStatusSymbol(_ status: UpdateStatus?) -> String {
    switch status {
    case .updateAvailable: "arrow.down.circle"
    case .upToDate: "checkmark.circle"
    case .unknown, .failed: "exclamationmark.circle"
    case .unsupported: "minus.circle"
    case nil: "clock"
    }
}
