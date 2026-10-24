import AppHarborCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class LibraryModel {
    var snapshot: InventorySnapshot?
    var selection: Set<InstallationID> = []
    var destination: SidebarDestination = .allSoftware
    var libraryViewMode: LibraryViewMode = .list {
        didSet { UserDefaults.standard.set(libraryViewMode.rawValue, forKey: "AppHarbor.libraryViewMode") }
    }
    var searchText = ""
    var kindFilter: ItemKindFilter = .all
    var sourceFilter: String?
    var isRefreshing = false
    var refreshError: String?
    var storageStatus: StorageStatus = .available
    var planDecision: PlanDecision?
    var planSheetMode: PlanSheetMode = .review
    var isInspectorPresented = true
    var taskRecords: [TaskRecord] = []
    var checkingUpdateIDs: Set<InstallationID> = []
    var isPreparingPlan = false
    var isExecutingOperation = false
    var isCancellingOperation = false
    var customScanLocations: [URL] = []
    var canChangeConfiguration: Bool { !isRefreshing && !isExecutingOperation && !isPreparingPlan && planDecision == nil }

    var homebrewExecutablesText = ""
    var npmExecutablesText = ""
    var npmNodeExecutablesText = ""
    var pipxExecutablesText = ""
    var pipxHomesText = ""
    var cargoExecutablesText = ""
    var cargoRootsText = ""

    @ObservationIgnored private var engine: AppHarborCoreEngine?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<InventorySnapshot, Never>?
    @ObservationIgnored private var operationTask: Task<TaskRecord, Never>?
    @ObservationIgnored private let store: any InstallationStoring

    init(engine: AppHarborCoreEngine? = nil) {
        let defaults = UserDefaults.standard
        libraryViewMode = LibraryViewMode(rawValue: defaults.string(forKey: "AppHarbor.libraryViewMode") ?? "") ?? .list
        customScanLocations = (defaults.stringArray(forKey: "AppHarbor.scanLocations") ?? []).map(URL.init(fileURLWithPath:))
        homebrewExecutablesText = Self.loadPaths("homebrewExecutables")
        npmExecutablesText = Self.loadPaths("npmExecutables")
        npmNodeExecutablesText = Self.loadPaths("npmNodeExecutables")
        pipxExecutablesText = Self.loadPaths("pipxExecutables")
        pipxHomesText = Self.loadPaths("pipxHomes")
        cargoExecutablesText = Self.loadPaths("cargoExecutables")
        cargoRootsText = Self.loadPaths("cargoRoots")
        let store = LocalJSONInstallationStore.applicationDefault()
        self.store = store
        let paths = ManagerPathConfiguration(homebrewExecutables: Self.lines(homebrewExecutablesText),
                                             npmExecutables: Self.lines(npmExecutablesText),
                                             npmNodeExecutables: Self.lines(npmNodeExecutablesText),
                                             pipxExecutables: Self.lines(pipxExecutablesText),
                                             pipxHomes: Self.lines(pipxHomesText),
                                             cargoExecutables: Self.lines(cargoExecutablesText),
                                             cargoRoots: Self.lines(cargoRootsText))
        let connectedEngine = engine ?? CoreEngineFactory.make(scanRoots: customScanLocations.map(\.path), paths: paths, store: store)
        self.engine = connectedEngine
        observe(connectedEngine)
        Task {
            snapshot = await connectedEngine.currentSnapshot()
            taskRecords = await store.loadTasks()
            storageStatus = await connectedEngine.storageStatus()
        }
    }

    private func configuredPaths() -> ManagerPathConfiguration {
        ManagerPathConfiguration(homebrewExecutables: Self.lines(homebrewExecutablesText),
                                 npmExecutables: Self.lines(npmExecutablesText),
                                 npmNodeExecutables: Self.lines(npmNodeExecutablesText),
                                 pipxExecutables: Self.lines(pipxExecutablesText),
                                 pipxHomes: Self.lines(pipxHomesText),
                                 cargoExecutables: Self.lines(cargoExecutablesText),
                                 cargoRoots: Self.lines(cargoRootsText))
    }

    private func reconnectEngine() {
        guard canChangeConfiguration else { return }
        let engine = CoreEngineFactory.make(scanRoots: customScanLocations.map(\.path), paths: configuredPaths(), store: store)
        self.engine = engine
        observe(engine)
        Task { await refresh() }
    }

    private func observe(_ engine: AppHarborCoreEngine) {
        eventTask?.cancel()
        eventTask = Task {
            let stream = await engine.events()
            for await event in stream {
                guard !Task.isCancelled else { break }
                switch event {
                case .inventoryChanged(let newSnapshot): snapshot = newSnapshot
                case .operationChanged(let record): upsert(record)
                }
            }
        }
    }

    private func upsert(_ record: TaskRecord) {
        if let index = taskRecords.firstIndex(where: { $0.id == record.id }) { taskRecords[index] = record }
        else { taskRecords.insert(record, at: 0) }
        taskRecords = Array(taskRecords.sorted { $0.startedAt > $1.startedAt }.prefix(200))
    }

    var installations: [Installation] { snapshot?.installations ?? [] }
    var managers: [ManagerInstance] { snapshot?.managers ?? [] }
    var coverage: [CoverageSnapshot] { snapshot?.coverage ?? [] }
    var selectedInstallation: Installation? {
        guard destination != .manageSources, destination != .activity,
              selection.count == 1, let id = selection.first else { return nil }
        return visibleInstallations.first { $0.identity == id }
    }

    func pruneSelection(to visibleIDs: Set<InstallationID>? = nil) {
        let allowed = visibleIDs ?? Set(visibleInstallations.map(\.identity))
        selection.formIntersection(allowed)
    }

    var visibleInstallations: [Installation] {
        installations.filter { item in
            let manager = managers.first { $0.id == item.identity.managerID }
            let sourceMatches = sourceFilter == nil || item.identity.managerID == sourceFilter
            let selectionMatches: Bool
            switch destination {
            case .allSoftware: selectionMatches = true
            case .applications: selectionMatches = item.kind == .appBundle || item.kind == .cask
            case .commandLine: selectionMatches = item.kind != .appBundle && item.kind != .cask
            case .updates: selectionMatches = item.updateSupported
            case .source(let sourceID): selectionMatches = item.identity.managerID == sourceID
            case .manageSources, .activity: selectionMatches = false
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let textMatches = query.isEmpty || [item.displayName, item.identity.nativeID, item.canonicalLocation,
                                               manager?.kind.rawValue ?? "", manager?.scope.displayName ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
            let kindMatches: Bool
            switch kindFilter {
            case .all: kindMatches = true
            case .applications: kindMatches = item.kind == .appBundle || item.kind == .cask
            case .commandLine: kindMatches = item.kind != .appBundle && item.kind != .cask
            }
            return selectionMatches && sourceMatches && textMatches && kindMatches
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func refresh() async {
        guard let engine, refreshTask == nil else { return }
        isRefreshing = true
        refreshError = nil
        let task = Task { await engine.refresh() }
        refreshTask = task
        snapshot = await task.value
        refreshTask = nil
        isRefreshing = false
        storageStatus = await engine.storageStatus()
    }

    func cancelRefresh() { refreshTask?.cancel() }

    func prepare(_ operation: ManagedOperation, for installation: Installation) async {
        guard let engine, !isExecutingOperation, !isPreparingPlan, planDecision == nil else { return }
        isPreparingPlan = true
        planSheetMode = .review
        let decision = await engine.prepare(operation: operation, installationID: installation.identity)
        planDecision = decision
        isPreparingPlan = false
    }

    func openRemovalGuide(for installation: Installation) async {
        guard let engine, !isExecutingOperation, !isPreparingPlan, planDecision == nil else { return }
        isPreparingPlan = true
        planSheetMode = .guide
        let decision = await engine.prepare(operation: .remove, installationID: installation.identity)
        switch decision {
        case .ready(let plan):
            let manager = managers.first { $0.id == installation.identity.managerID }
            let guide = RemovalGuidance(title: "Remove \(installation.displayName) manually", steps: [
                "This installation is managed by \(manager.map { sourceName($0.kind) } ?? "its package manager") in \(manager?.scope.displayName ?? installation.identity.scopeID).",
                "If you choose to continue, run the copied command yourself in Terminal. AppHarbor will only copy it; this guide does not execute it.",
                "Return to AppHarbor and refresh to check this same installation."
            ], displayCommand: plan.previewCommand, isVerified: true)
            planDecision = .guidance(guide, reason: "This copy-only command was prepared for the selected installation and its explicit scope.")
        case .guidance(let guide, let reason): planDecision = .guidance(guide, reason: reason)
        case .blocked(let reason): planDecision = .blocked(reason: reason)
        }
        isPreparingPlan = false
    }

    func checkUpdate(for installation: Installation) async {
        guard let engine, !installation.isStale else { return }
        checkingUpdateIDs.insert(installation.identity)
        defer { checkingUpdateIDs.remove(installation.identity) }
        _ = await engine.checkUpdate(installationID: installation.identity)
    }

    func execute(_ plan: ActionPlan) async {
        guard let engine, operationTask == nil else { return }
        isExecutingOperation = true
        isCancellingOperation = false
        let task = Task { await engine.execute(planID: plan.id, confirmed: true) }
        operationTask = task
        let record = await task.value
        upsert(record)
        snapshot = await engine.currentSnapshot()
        storageStatus = await engine.storageStatus()
        operationTask = nil
        isExecutingOperation = false
        isCancellingOperation = false
        planDecision = nil
    }

    func cancelOperation() {
        guard operationTask != nil else { return }
        isCancellingOperation = true
        operationTask?.cancel()
    }

    func applyManagerPaths() {
        guard canChangeConfiguration else { return }
        let defaults = UserDefaults.standard
        defaults.set(Self.lines(homebrewExecutablesText), forKey: "AppHarbor.homebrewExecutables")
        defaults.set(Self.lines(npmExecutablesText), forKey: "AppHarbor.npmExecutables")
        defaults.set(Self.lines(npmNodeExecutablesText), forKey: "AppHarbor.npmNodeExecutables")
        defaults.set(Self.lines(pipxExecutablesText), forKey: "AppHarbor.pipxExecutables")
        defaults.set(Self.lines(pipxHomesText), forKey: "AppHarbor.pipxHomes")
        defaults.set(Self.lines(cargoExecutablesText), forKey: "AppHarbor.cargoExecutables")
        defaults.set(Self.lines(cargoRootsText), forKey: "AppHarbor.cargoRoots")
        reconnectEngine()
    }

    func addScanLocation(_ url: URL) {
        guard !customScanLocations.contains(url), canChangeConfiguration else { return }
        customScanLocations.append(url)
        UserDefaults.standard.set(customScanLocations.map(\.path), forKey: "AppHarbor.scanLocations")
        reconnectEngine()
    }

    func removeScanLocation(_ url: URL) {
        guard canChangeConfiguration else { return }
        customScanLocations.removeAll { $0 == url }
        UserDefaults.standard.set(customScanLocations.map(\.path), forKey: "AppHarbor.scanLocations")
        reconnectEngine()
    }

    private static func loadPaths(_ key: String) -> String { (UserDefaults.standard.stringArray(forKey: "AppHarbor.\(key)") ?? []).joined(separator: "\n") }
    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { ($0.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath }.filter { !$0.isEmpty && $0.hasPrefix("/") }
    }

    deinit { eventTask?.cancel(); refreshTask?.cancel(); operationTask?.cancel() }
}

enum SidebarDestination: Hashable {
    case allSoftware, applications, commandLine, updates, activity, manageSources
    case source(String)
}

enum ItemKindFilter: String, CaseIterable, Identifiable {
    case all, applications, commandLine
    var id: String { rawValue }
}

enum PlanSheetMode: Equatable { case review, guide }

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
