import AppHarborCore
import AppHarborMCPBridge
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
        didSet { preferences.set(libraryViewMode.rawValue, forKey: "AppHarbor.libraryViewMode") }
    }
    var searchText = ""
    var kindFilter: ItemKindFilter = .all
    var sourceFilter: String?
    var isRefreshing = false
    var refreshError: String?
    var storageStatus: StorageStatus = .available
    var planDecision: PlanDecision? {
        didSet {
            if oldValue == nil, planDecision != nil { planDecisionPresentationToken = UUID() }
            if oldValue != nil, planDecision == nil,
               presentedPlanSheetToken == planDecisionPresentationToken,
               let token = presentedPlanSheetToken {
                pendingPlanSheetDismissals.append(PlanSheetDismissal(presentationToken: token,
                                                                     mcpRequestID: presentedPlanSheetMCPRequestID))
                planDecisionSheetDismissalPending = true
                presentedPlanSheetToken = nil
                presentedPlanSheetMCPRequestID = nil
            }
        }
    }
    var planDecisionSheetDismissalPending = false
    var planDecisionPresentationToken = UUID()
    var presentedPlanSheetToken: UUID?
    var presentedPlanSheetMCPRequestID: String?
    var pendingPlanSheetDismissals: [PlanSheetDismissal] = []
    var planSheetMode: PlanSheetMode = .review
    var isInspectorPresented = true
    var taskRecords: [TaskRecord] = []
    var checkingUpdateIDs: Set<InstallationID> = []
    var isPreparingPlan = false
    var isExecutingOperation = false
    var isCancellingOperation = false
    var customScanLocations: [URL] = []
    var canChangeConfiguration: Bool {
        !isRefreshing && !isExecutingOperation && !isPreparingPlan && planDecision == nil && !planDecisionSheetDismissalPending
    }

    var homebrewExecutablesText = ""
    var npmExecutablesText = ""
    var npmNodeExecutablesText = ""
    var pipxExecutablesText = ""
    var pipxHomesText = ""
    var cargoExecutablesText = ""
    var cargoRootsText = ""

    var mcpBridgeEnabled = false {
        didSet {
            guard oldValue != mcpBridgeEnabled else { return }
            preferences.set(mcpBridgeEnabled, forKey: "AppHarbor.mcpBridgeEnabled")
            mcpConfigurationGeneration &+= 1
            if mcpBridgeEnabled { startMCPBridge() }
            else {
                stopMCPBridge()
                invalidatePendingMCPReview(message: "The local bridge was turned off before confirmation.")
            }
        }
    }
    var mcpActionRequestsEnabled = false {
        didSet {
            guard oldValue != mcpActionRequestsEnabled else { return }
            preferences.set(mcpActionRequestsEnabled, forKey: "AppHarbor.mcpActionRequestsEnabled")
            mcpConfigurationGeneration &+= 1
            if !mcpActionRequestsEnabled {
                invalidatePendingMCPReview(message: "AI action requests were turned off before confirmation.")
            }
        }
    }
    var mcpBridgeStatus = "Off"
    var mcpLatestRequestStatus = "No requests yet"
    var mcpReviewContext: String? { activeMCPReview.map { "Requested by a connected AI client for \($0.displayName). Review this exact target and action yourself in AppHarbor." } }

    @ObservationIgnored var engine: AppHarborCoreEngine?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<InventorySnapshot, Never>?
    @ObservationIgnored var operationTask: Task<TaskRecord, Never>?
    @ObservationIgnored let store: any InstallationStoring
    @ObservationIgnored var preferences: UserDefaults
    @ObservationIgnored var injectedMCPServer: MCPBridgeServer?
    @ObservationIgnored var mcpReviewTTL: TimeInterval
    @ObservationIgnored var mcpServer: MCPBridgeServer?
    @ObservationIgnored var mcpExpiryTask: Task<Void, Never>?
    @ObservationIgnored var mcpConfigurationGeneration = 0
    @ObservationIgnored var mcpBridgeGeneration = 0
    @ObservationIgnored var activeMCPReview: PendingMCPReview?
    @ObservationIgnored var mcpRequestRecords: [String: MCPRequestRecord] = [:]
    @ObservationIgnored var mcpRequestOrder: [String] = []
    @ObservationIgnored var mcpPlanProvenance: [UUID: MCPPlanProvenance] = [:]
    @ObservationIgnored var mcpPlanProvenanceOrder: [UUID] = []

    init(engine: AppHarborCoreEngine? = nil,
         store injectedStore: (any InstallationStoring)? = nil,
         preferences: UserDefaults = .standard,
         mcpServer: MCPBridgeServer? = nil,
         mcpReviewTTL: TimeInterval = 300) {
        self.preferences = preferences
        self.injectedMCPServer = mcpServer
        self.mcpReviewTTL = mcpReviewTTL
        let defaults = preferences
        libraryViewMode = LibraryViewMode(rawValue: defaults.string(forKey: "AppHarbor.libraryViewMode") ?? "") ?? .list
        customScanLocations = (defaults.stringArray(forKey: "AppHarbor.scanLocations") ?? []).map(URL.init(fileURLWithPath:))
        homebrewExecutablesText = Self.loadPaths("homebrewExecutables", defaults: defaults)
        npmExecutablesText = Self.loadPaths("npmExecutables", defaults: defaults)
        npmNodeExecutablesText = Self.loadPaths("npmNodeExecutables", defaults: defaults)
        pipxExecutablesText = Self.loadPaths("pipxExecutables", defaults: defaults)
        pipxHomesText = Self.loadPaths("pipxHomes", defaults: defaults)
        cargoExecutablesText = Self.loadPaths("cargoExecutables", defaults: defaults)
        cargoRootsText = Self.loadPaths("cargoRoots", defaults: defaults)
        let store = injectedStore ?? (engine == nil ? LocalJSONInstallationStore.applicationDefault() : InMemoryInstallationStore())
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
        mcpBridgeEnabled = defaults.bool(forKey: "AppHarbor.mcpBridgeEnabled")
        mcpActionRequestsEnabled = defaults.bool(forKey: "AppHarbor.mcpActionRequestsEnabled")
        observe(connectedEngine)
        Task {
            snapshot = await connectedEngine.currentSnapshot()
            taskRecords = await store.loadTasks()
            storageStatus = await connectedEngine.storageStatus()
        }
        if mcpBridgeEnabled { startMCPBridge() }
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

    func upsert(_ record: TaskRecord) {
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

    func usesNativeTrash(for installation: Installation) -> Bool {
        installation.kind == .appBundle && managers.first { $0.id == installation.identity.managerID }?.kind == .appBundle
    }

    func nativeTrashRemovalAvailable(for installation: Installation) -> Bool {
        guard usesNativeTrash(for: installation), installation.removalSupported, !installation.isProtected,
              installation.ownership == .verified, !installation.isStale,
              let manager = managers.first(where: { $0.id == installation.identity.managerID }) else { return false }
        return manager.removalSupported && manager.presence == .present
    }

    func removalReviewAvailable(for installation: Installation) -> Bool {
        guard canChangeConfiguration, installation.removalSupported, !installation.isProtected,
              installation.ownership == .verified, !installation.isStale else { return false }
        return !usesNativeTrash(for: installation) || nativeTrashRemovalAvailable(for: installation)
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

    func refresh(reservationAlreadySet: Bool = false) async {
        guard let engine, refreshTask == nil,
              reservationAlreadySet ? isRefreshing : !isRefreshing else { return }
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
        guard let engine, canChangeConfiguration else { return }
        isPreparingPlan = true
        planSheetMode = .review
        let decision = await engine.prepare(operation: operation, installationID: installation.identity)
        planDecision = decision
        isPreparingPlan = false
    }

    func openRemovalGuide(for installation: Installation) async {
        guard let engine, canChangeConfiguration else { return }
        isPreparingPlan = true
        planSheetMode = .guide
        let decision = await engine.prepare(operation: .remove, installationID: installation.identity)
        switch decision {
        case .ready(let plan):
            switch plan.execution {
            case .appBundleTrash:
                let guide = RemovalGuidance(title: "Move \(installation.displayName) to Finder Trash", steps: [
                    "Choose Move to Trash… to review and confirm this exact app bundle.",
                    "Only this app bundle moves. Installer records and support files may remain; use the developer’s uninstaller when required.",
                    "You can restore the app from Finder Trash until Trash is emptied."
                ], isVerified: true)
                planDecision = .guidance(guide, reason: "AppHarbor prepared a verified Finder Trash action for this app bundle; it does not run a removal command.")
            case .process:
                let manager = managers.first { $0.id == installation.identity.managerID }
                let guide = RemovalGuidance(title: "Remove \(installation.displayName) manually", steps: [
                    "This installation is managed by \(manager.map { sourceName($0.kind) } ?? "its package manager") in \(manager?.scope.displayName ?? installation.identity.scopeID).",
                    "If you choose to continue, run the copied command yourself in Terminal. AppHarbor will only copy it; this guide does not execute it.",
                    "Return to AppHarbor and refresh to check this same installation."
                ], displayCommand: plan.previewCommand, isVerified: true)
                planDecision = .guidance(guide, reason: "This copy-only command was prepared for the selected installation and its explicit scope.")
            }
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

    func cancelOperation() {
        guard operationTask != nil else { return }
        isCancellingOperation = true
        operationTask?.cancel()
    }

    func applyManagerPaths() {
        guard canChangeConfiguration else { return }
        let defaults = preferences
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
        preferences.set(customScanLocations.map(\.path), forKey: "AppHarbor.scanLocations")
        reconnectEngine()
    }

    func removeScanLocation(_ url: URL) {
        guard canChangeConfiguration else { return }
        customScanLocations.removeAll { $0 == url }
        preferences.set(customScanLocations.map(\.path), forKey: "AppHarbor.scanLocations")
        reconnectEngine()
    }

    private static func loadPaths(_ key: String, defaults: UserDefaults) -> String { (defaults.stringArray(forKey: "AppHarbor.\(key)") ?? []).joined(separator: "\n") }
    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { ($0.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath }.filter { !$0.isEmpty && $0.hasPrefix("/") }
    }

    deinit { eventTask?.cancel(); refreshTask?.cancel(); operationTask?.cancel(); mcpExpiryTask?.cancel(); mcpServer?.stop() }
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
