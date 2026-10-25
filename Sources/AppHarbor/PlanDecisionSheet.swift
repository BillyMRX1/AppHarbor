import AppKit
import AppHarborCore
import SwiftUI

struct PlanDecisionSheet: View {
    let decision: PlanDecision
    let mode: PlanSheetMode
    let reviewContext: String?
    let isExecuting: Bool
    let isCancelling: Bool
    let onConfirm: (ActionPlan) -> Void
    let onCancelOperation: () -> Void
    let onClose: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isExecuting {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(isCancelling ? "Canceling operation…" : "Operation in progress…")
                                .font(.callout.weight(.medium))
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let reviewContext {
                        Label(reviewContext, systemImage: "network")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    switch decision {
                    case .ready(let plan): review(plan)
                    case .guidance(let guide, let reason): guidance(guide, reason: reason)
                    case .blocked(let reason):
                        Label("Action Unavailable", systemImage: "hand.raised")
                            .font(.title2.weight(.semibold))
                        Text(reason).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("You can still inspect the installation details or refresh the inventory.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                if isExecuting {
                    Button(isCancelling ? "Canceling…" : "Cancel Operation", action: onCancelOperation)
                        .disabled(isCancelling)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Close", action: onClose)
                        .keyboardShortcut(.cancelAction)
                        .focused($cancelFocused)
                }
                if mode == .review, case let .ready(plan) = decision, !isExecuting {
                    Button(confirmTitle(for: plan), role: plan.operation == .remove ? .destructive : nil) {
                        onConfirm(plan)
                    }
                    // Deliberately no Return/default shortcut for a destructive action.
                    .accessibilityHint(isNativeTrash(plan) ? "Moves this exact app bundle to Finder Trash." : "Runs the reviewed operation for this exact installation.")
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .interactiveDismissDisabled(isExecuting)
        .onAppear { cancelFocused = true }
    }

    @ViewBuilder private func review(_ plan: ActionPlan) -> some View {
        Label(reviewTitle(for: plan), systemImage: plan.operation == .remove ? "trash" : "arrow.down.circle")
            .font(.title2.weight(.semibold))
        Text(isNativeTrash(plan)
             ? "AppHarbor will re-check this app bundle immediately before moving it to Finder Trash."
             : "AppHarbor will re-check the target and manager immediately before starting.")
            .font(.callout).foregroundStyle(.secondary)
        GroupBox("Exact target") {
            VStack(alignment: .leading, spacing: 5) {
                Text(plan.installationID.nativeID).font(.headline)
                Text("Location: \(targetPath(for: plan))")
                Text("Scope: \(plan.installationID.scopeID)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        if case .appBundleTrash = plan.execution {
            GroupBox("Move to Trash") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Only this app bundle moves to Finder Trash; installer or package-manager records may remain.")
                    Text("Support files, settings, documents, and subscriptions may remain. Use the developer’s uninstaller when required.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        } else if case .process = plan.execution {
            GroupBox("Command") {
                HStack(alignment: .top, spacing: 10) {
                    Text(plan.previewCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(plan.previewCommand, forType: .string)
                    } label: { Label("Copy Command", systemImage: "doc.on.doc") }
                        .labelStyle(.iconOnly)
                        .help("Copy complete command to clipboard")
                        .accessibilityLabel("Copy Command")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if !plan.knownEffects.isEmpty || !plan.unknownEffects.isEmpty {
            GroupBox("Effects") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(plan.knownEffects, id: \.self) { Text("• \($0)") }
                    ForEach(plan.unknownEffects, id: \.self) { Text("Uncertain: \($0)").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if isNativeTrash(plan) {
            Text("You can restore the app from Finder Trash until Trash is emptied. AppHarbor does not provide an Undo command.")
                .font(.callout.weight(.medium))
        } else {
            Text("AppHarbor cannot undo this operation.")
                .font(.callout.weight(.medium))
        }
        Text(plan.expectedResult).font(.callout).foregroundStyle(.secondary)
        if plan.privilegeRequired {
            Label("This plan requires elevated permission and cannot be run by AppHarbor.", systemImage: "lock")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func guidance(_ guide: RemovalGuidance, reason: String) -> some View {
        Label(guide.title, systemImage: "text.book.closed")
            .font(.title2.weight(.semibold))
        Text(reason).foregroundStyle(.secondary)
        ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
                Text(step).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let command = guide.displayCommand {
            GroupBox("Manual command · copy only") {
                HStack(alignment: .top) {
                    Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy Command").accessibilityLabel("Copy Command")
                }
            }
        }
        if let url = guide.sourceURL {
            Link(destination: url) { Label("Open source instructions", systemImage: "arrow.up.right.square") }
        }
        Text(guide.isVerified ? "Instructions are based on the detected source." : "Source instructions could not be verified for this installation.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private func isNativeTrash(_ plan: ActionPlan) -> Bool {
    if case .appBundleTrash = plan.execution { return true }
    return false
}

private func targetPath(for plan: ActionPlan) -> String {
    if case let .appBundleTrash(target) = plan.execution { return target.appPath }
    return plan.installationID.canonicalLocation
}

private func reviewTitle(for plan: ActionPlan) -> String {
    isNativeTrash(plan) ? "Review Move to Trash" : (plan.operation == .remove ? "Review Removal" : "Review Update")
}

private func confirmTitle(for plan: ActionPlan) -> String {
    isNativeTrash(plan) ? "Move to Trash" : (plan.operation == .remove ? "Confirm Removal" : "Confirm Update")
}

extension PlanDecision: Identifiable {
    public var id: String {
        switch self {
        case .ready(let plan): "ready-\(plan.id)"
        case .guidance(let guide, let reason): "guide-\(guide.title)-\(reason)"
        case .blocked(let reason): "blocked-\(reason)"
        }
    }
}
