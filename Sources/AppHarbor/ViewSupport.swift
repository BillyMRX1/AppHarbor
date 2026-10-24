import AppHarborCore
import Foundation

func sourceName(_ kind: ManagerKind) -> String {
    switch kind {
    case .appBundle: "Applications"
    case .homebrew: "Homebrew"
    case .npm: "npm global"
    case .pipx: "pipx"
    case .cargo: "Cargo"
    case .other: "Other"
    }
}

func sourceSymbol(_ kind: ManagerKind) -> String {
    switch kind {
    case .appBundle: "square.grid.2x2"
    case .homebrew: "shippingbox"
    case .npm, .pipx, .cargo: "terminal"
    case .other: "questionmark.folder"
    }
}

func kindName(_ kind: InstallationKind) -> String {
    switch kind {
    case .appBundle, .cask: "Application"
    case .formula, .npmPackage, .pipxEnvironment, .cargoPackage: "Command Line"
    case .other: "Other"
    }
}

func presenceName(_ presence: ManagerPresence) -> String {
    switch presence {
    case .present: "Present"
    case .absent: "Absent"
    case .unavailable: "Unavailable"
    case .unsupportedVersion: "Unsupported version"
    }
}

func titleForDestination(_ destination: SidebarDestination) -> String {
    switch destination {
    case .allSoftware: "All Software"
    case .applications: "Applications"
    case .commandLine: "Command Line"
    case .updates: "Updates"
    case .activity: "Activity"
    case .manageSources: "Sources"
    case .source: "Source Inventory"
    }
}

func removalDisabledReason(_ item: Installation) -> String {
    if item.isStale { return "This inventory row is stale. Refresh before reviewing removal." }
    if item.isProtected { return item.protectionReason ?? "Protected software cannot be removed." }
    if item.ownership != .verified { return "AppHarbor cannot verify the owning source." }
    if !item.removalSupported { return "No verified direct-removal capability is available." }
    return "Remove this installation after reviewing the exact target and effects."
}

func taskStateName(_ task: TaskRecord) -> String {
    switch task.state {
    case .awaitingConfirmation: "Awaiting confirmation"
    case .running: "Running"
    case .verifying: "Verifying"
    case .succeeded: task.verification == .verifiedRemoved ? "Verified Removed" : "Verified Updated"
    case .failed: "Could Not Complete"
    case .outcomeUnknown: "Verification Incomplete"
    case .invalidated: "Review Required"
    }
}

func taskSymbol(_ state: TaskState) -> String {
    switch state {
    case .awaitingConfirmation: "clock"
    case .running: "arrow.triangle.2.circlepath"
    case .verifying: "magnifyingglass"
    case .succeeded: "checkmark.circle"
    case .failed: "xmark.circle"
    case .outcomeUnknown: "questionmark.circle"
    case .invalidated: "exclamationmark.circle"
    }
}


func managerLabel(_ manager: ManagerInstance, among managers: [ManagerInstance]) -> String {
    let peers = managers.filter { $0.kind == manager.kind }
    guard peers.count > 1 else { return sourceName(manager.kind) }
    let path = manager.scope.canonicalRoot ?? manager.scope.displayName
    let components = path.split(separator: "/").suffix(2).joined(separator: "/")
    return "\(sourceName(manager.kind)) · \(components.isEmpty ? manager.executablePath : components)"
}
