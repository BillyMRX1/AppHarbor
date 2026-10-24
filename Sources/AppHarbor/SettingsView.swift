import AppKit
import AppHarborCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: LibraryModel
    @State private var selectedTab = "General"
    @State private var showingDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            if let storageMessage = storageWarning {
                Label(storageMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 12)
            }
            TabView(selection: $selectedTab) {
                generalTab.tabItem { Label("General", systemImage: "gearshape") }.tag("General")
                managerPathsTab.tabItem { Label("Sources", systemImage: "shippingbox") }.tag("Sources")
                privacyTab.tabItem { Label("Privacy", systemImage: "hand.raised") }.tag("Privacy")
            }
            .padding(18)
        }
        .sheet(isPresented: $showingDiagnostics) { DiagnosticsExportView(model: model) }
    }

    private var generalTab: some View {
        Form {
            Section("Application Inventory") {
                Text("AppHarbor scans standard application locations and supported manager scopes. It does not traverse the whole disk.")
                    .foregroundStyle(.secondary)
                LabeledContent("Default locations", value: "/Applications · ~/Applications")
                Button("Add Scan Location…", action: chooseScanLocation)
                    .disabled(!model.canChangeConfiguration)
            }
            Section("Additional Scan Locations") {
                if model.customScanLocations.isEmpty {
                    Text("No additional locations selected.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.customScanLocations, id: \.path) { url in
                        HStack {
                            Text(url.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            Button("Remove") { model.removeScanLocation(url) }
                                .buttonStyle(.borderless).disabled(!model.canChangeConfiguration)
                                .accessibilityLabel("Remove scan location \(url.path)")
                        }
                    }
                }
                Text("Selected folders are used for application inventory only. AppHarbor does not request Full Disk Access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Scan Control") {
                Button(model.isRefreshing ? "Cancel Inventory Scan" : "Refresh Inventory") {
                    if model.isRefreshing { model.cancelRefresh() }
                    else { Task { await model.refresh() } }
                }
                if let error = model.refreshError { Text(error).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private var managerPathsTab: some View {
        Form {
            Section("Explicit Manager Locations") {
                Text("One absolute path per line. Empty fields use supported default discovery. Changes are saved locally and trigger a new inventory scan.")
                    .font(.callout).foregroundStyle(.secondary)
                PathListEditor("Homebrew executables", hint: "/opt/homebrew/bin/brew", text: $model.homebrewExecutablesText)
                PathListEditor("npm executables", hint: "/opt/homebrew/bin/npm", text: $model.npmExecutablesText)
                PathListEditor("Node executables", hint: "/opt/homebrew/bin/node", text: $model.npmNodeExecutablesText)
                PathListEditor("pipx executables", hint: "/opt/homebrew/bin/pipx", text: $model.pipxExecutablesText)
                PathListEditor("pipx homes", hint: "~/.local/pipx", text: $model.pipxHomesText)
                PathListEditor("Cargo executables", hint: "/Users/you/.cargo/bin/cargo", text: $model.cargoExecutablesText)
                PathListEditor("Cargo installation roots", hint: "~/.cargo", text: $model.cargoRootsText)
                Button("Apply Source Paths and Refresh") { model.applyManagerPaths() }
                    .disabled(!model.canChangeConfiguration)
            }
            Section("Limits") {
                Text("A configured manager path identifies a source to inspect; it does not authorize every action. Unsupported scopes remain Unknown or guidance-only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var privacyTab: some View {
        Form {
            Section("Local Data") {
                Text("Inventory and redacted operation history are stored locally. No account or analytics service is used.")
                LabeledContent("Cache", value: "Expires after 30 days")
                LabeledContent("Activity", value: "Up to 200 records, retained for 30 days")
                Button("Review Redacted Diagnostics…") { showingDiagnostics = true }
            }
            Section("Permissions") {
                Text("Baseline inventory does not require root, Full Disk Access, or Accessibility access. Inaccessible locations remain partial.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var storageWarning: String? {
        switch model.storageStatus {
        case .available: nil
        case .readFailure(let message): "Could not read the saved local inventory: \(message)"
        case .writeFailure(let message): "Could not save the local inventory: \(message)"
        }
    }

    private func chooseScanLocation() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application Scan Location"
        panel.message = "AppHarbor will inspect application bundles in this folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url { model.addScanLocation(url) }
    }
}

private struct PathListEditor: View {
    let title: String
    let hint: String
    @Binding var text: String

    init(_ title: String, hint: String, text: Binding<String>) {
        self.title = title; self.hint = hint; self._text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 42, maxHeight: 64)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(hint).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                            .padding(.leading, 5).padding(.top, 7).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(title)
        }
    }
}

private struct DiagnosticsExportView: View {
    @Bindable var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?

    private var json: String {
        let sources: [[String: Any]] = model.managers.map { manager in
            ["source": sourceName(manager.kind), "presence": presenceName(manager.presence),
             "scope": "[redacted]",
             "inventory": coverageForManager(manager, coverage: model.coverage)?.state.rawValue ?? "unknown",
             "removalCapability": manager.removalSupported ? "supported" : "guidance",
             "updateCapability": manager.updateSupported ? "supported" : "unknown"]
        }
        let coverage: [[String: Any]] = model.coverage.map { item in
            ["source": item.sourceName, "scope": "[redacted]", "state": item.state.rawValue,
             "itemCount": item.itemCount, "warning": item.warning == nil ? "" : "Details redacted."]
        }
        let activity: [[String: Any]] = model.taskRecords.map { item in
            ["operation": item.operation.rawValue, "state": item.state.rawValue, "verification": item.verification.rawValue,
             "summary": "Summary details redacted.", "startedAt": ISO8601DateFormatter().string(from: item.startedAt)]
        }
        let object: [String: Any] = ["app": "AppHarbor", "createdAt": ISO8601DateFormatter().string(from: .now),
                                      "platform": ProcessInfo.processInfo.operatingSystemVersionString,
                                      "installationCount": model.installations.count, "sources": sources,
                                      "coverage": coverage, "activity": activity, "storageStatus": storageStatusDescription(model.storageStatus)]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Redacted Diagnostics").font(.title2.weight(.semibold))
            Text("Preview this local export before saving. It includes source capability and coverage counts, not package names, IDs, command lines, or raw process output. Path-like values, URLs, and credentials are redacted.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 300)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Redacted diagnostics preview")
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Redacted Diagnostics…", action: save)
            }
        }
        .padding(20)
        .frame(width: 680, height: 540)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AppHarbor-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do { try Data(json.utf8).write(to: url, options: .atomic); dismiss() }
            catch { saveError = "Could not save diagnostics: \(error.localizedDescription)" }
        }
    }

    private func storageStatusDescription(_ status: StorageStatus) -> String {
        switch status {
        case .available: "available"
        case .readFailure: "read failure"
        case .writeFailure: "write failure"
        }
    }

}
