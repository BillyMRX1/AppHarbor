import SwiftUI

@main
struct AppHarborApp: App {
    @State private var model = LibraryModel()

    var body: some Scene {
        WindowGroup {
            MainWindowView(model: model)
                .frame(minWidth: 980, minHeight: 680)
                .task { await model.refresh() }
        }
        .defaultSize(width: 1360, height: 850)
        .commands { AppHarborCommands(model: model) }

        Settings {
            SettingsView(model: model)
                .frame(width: 640, height: 600)
        }

    }
}

private struct AppHarborCommands: Commands {
    let model: LibraryModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(model.isRefreshing ? "Cancel Inventory Scan" : "Refresh Inventory") {
                if model.isRefreshing { model.cancelRefresh() }
                else { Task { await model.refresh() } }
            }
                .keyboardShortcut("r", modifiers: [.command])
        }
        CommandMenu("Software") {
            Button("How to Remove Selected…") {
                guard let item = model.selectedInstallation else { return }
                Task { await model.openRemovalGuide(for: item) }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model.selectedInstallation == nil || model.isExecutingOperation || model.isPreparingPlan || model.planDecision != nil)
            Button("Remove Selected…") {
                guard let item = model.selectedInstallation else { return }
                Task { await model.prepare(.remove, for: item) }
            }
            .disabled(model.selectedInstallation == nil || model.selectedInstallation.map { !$0.removalSupported || $0.isProtected || $0.isStale || $0.ownership != .verified } ?? true || model.isExecutingOperation || model.isPreparingPlan || model.planDecision != nil)
        }
    }
}
