import Foundation
import Darwin

private struct StoredAppHarborState: Codable {
    var schemaVersion: Int = 1
    var snapshot: InventorySnapshot
    var tasks: [TaskRecord]
}

/// Local normalized cache and redacted operation summaries. No raw process output or command text is stored.
public actor LocalJSONInstallationStore: InstallationStoring {
    private let fileURL: URL
    private var loadedState: StoredAppHarborState?
    private var status: StorageStatus = .available
    private var readFailed = false
    private let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    private let maximumTasks = 200

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func applicationDefault(fileManager: FileManager = .default) -> LocalJSONInstallationStore {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return LocalJSONInstallationStore(fileURL: base.appendingPathComponent("AppHarbor/state.json"))
    }

    public func loadSnapshot() -> InventorySnapshot {
        var state = loadState()
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        state.snapshot.installations = state.snapshot.installations.compactMap { item in
            guard item.observedAt >= cutoff else { return nil }
            var retained = item
            retained.isStale = true
            return retained
        }
        state.tasks = pruneTasks(state.tasks, cutoff: cutoff)
        loadedState = state
        return state.snapshot
    }

    public func saveSnapshot(_ snapshot: InventorySnapshot) {
        var state = loadState()
        state.snapshot = snapshot
        state.tasks = pruneTasks(state.tasks, cutoff: Date().addingTimeInterval(-retentionInterval))
        loadedState = state
        persist(state)
    }

    public func appendTask(_ record: TaskRecord) {
        var state = loadState()
        state.tasks.removeAll { $0.id == record.id }; state.tasks.append(record)
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        state.tasks = pruneTasks(state.tasks, cutoff: cutoff)
        loadedState = state
        persist(state)
    }

    public func storageStatus() async -> StorageStatus { status }

    public func loadTasks() -> [TaskRecord] {
        var state = loadState()
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        state.tasks = pruneTasks(state.tasks, cutoff: cutoff)
        loadedState = state; persist(state)
        return state.tasks
    }

    private func loadState() -> StoredAppHarborState {
        if let loadedState { return loadedState }
        let empty = StoredAppHarborState(snapshot: InventorySnapshot(installations: [], managers: [], coverage: []), tasks: [])
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return empty }
        do {
            let data = try Data(contentsOf: fileURL)
            var decoded = try JSONDecoder().decode(StoredAppHarborState.self, from: data)
            guard decoded.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
            decoded.tasks = normalizeInterruptedTasks(decoded.tasks)
            loadedState = decoded
            return decoded
        } catch {
            readFailed = true; status = .readFailure("Cached AppHarbor data could not be read; it has been preserved for recovery.")
            return empty
        }
    }

    private func pruneTasks(_ tasks: [TaskRecord], cutoff: Date) -> [TaskRecord] {
        Array(tasks.filter { $0.startedAt >= cutoff }.suffix(maximumTasks))
    }

    private func normalizeInterruptedTasks(_ tasks: [TaskRecord]) -> [TaskRecord] {
        tasks.map { task in
            var retained = task
            if retained.state == .running || retained.state == .verifying || retained.state == .awaitingConfirmation {
                retained.state = .outcomeUnknown; retained.completedAt = .now
                retained.redactedSummary = "AppHarbor exited during this operation. Refresh and verify the installation before retrying."
            }
            return retained
        }
    }

    private func redactedState(_ source: StoredAppHarborState) -> StoredAppHarborState {
        var state = source
        for index in state.snapshot.installations.indices {
            state.snapshot.installations[index].displayName = PrivacyRedactor.redact(state.snapshot.installations[index].displayName)
            state.snapshot.installations[index].version = state.snapshot.installations[index].version.map(PrivacyRedactor.redact)
            state.snapshot.installations[index].bundleIdentifier = state.snapshot.installations[index].bundleIdentifier.map(PrivacyRedactor.redact)
            state.snapshot.installations[index].protectionReason = state.snapshot.installations[index].protectionReason.map(PrivacyRedactor.redact)
            for evidenceIndex in state.snapshot.installations[index].evidence.indices {
                state.snapshot.installations[index].evidence[evidenceIndex].label = PrivacyRedactor.redact(state.snapshot.installations[index].evidence[evidenceIndex].label)
                state.snapshot.installations[index].evidence[evidenceIndex].value = PrivacyRedactor.redact(state.snapshot.installations[index].evidence[evidenceIndex].value)
            }
        }
        for index in state.snapshot.managers.indices {
            state.snapshot.managers[index].version = state.snapshot.managers[index].version.map(PrivacyRedactor.redact)
            state.snapshot.managers[index].architecture = state.snapshot.managers[index].architecture.map(PrivacyRedactor.redact)
            state.snapshot.managers[index].scope.displayName = PrivacyRedactor.redact(state.snapshot.managers[index].scope.displayName)
            for evidenceIndex in state.snapshot.managers[index].evidence.indices {
                state.snapshot.managers[index].evidence[evidenceIndex].label = PrivacyRedactor.redact(state.snapshot.managers[index].evidence[evidenceIndex].label)
                state.snapshot.managers[index].evidence[evidenceIndex].value = PrivacyRedactor.redact(state.snapshot.managers[index].evidence[evidenceIndex].value)
            }
        }
        for index in state.snapshot.coverage.indices {
            state.snapshot.coverage[index].sourceName = PrivacyRedactor.redact(state.snapshot.coverage[index].sourceName)
            state.snapshot.coverage[index].omittedScopes = state.snapshot.coverage[index].omittedScopes.map(PrivacyRedactor.redact)
            state.snapshot.coverage[index].warning = state.snapshot.coverage[index].warning.map(PrivacyRedactor.redact)
        }
        for index in state.snapshot.updateChecks.indices {
            state.snapshot.updateChecks[index].currentVersion = state.snapshot.updateChecks[index].currentVersion.map(PrivacyRedactor.redact)
            state.snapshot.updateChecks[index].availableVersion = state.snapshot.updateChecks[index].availableVersion.map(PrivacyRedactor.redact)
            state.snapshot.updateChecks[index].explanation = state.snapshot.updateChecks[index].explanation.map(PrivacyRedactor.redact)
        }
        for index in state.tasks.indices { state.tasks[index].redactedSummary = PrivacyRedactor.redact(state.tasks[index].redactedSummary) }
        return state
    }

    private func persist(_ state: StoredAppHarborState) {
        guard !readFailed else { return }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = chmod(directory.path, mode_t(0o700))
            let data = try JSONEncoder().encode(redactedState(state))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            _ = chmod(fileURL.path, mode_t(0o600))
            status = .available
        } catch {
            status = .writeFailure("AppHarbor could not save its local inventory or activity history.")
        }
    }
}
