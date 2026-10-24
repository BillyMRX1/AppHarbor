import AppKit
import AppHarborCore
import SwiftUI

struct PlanDecisionSheet: View {
    let decision: PlanDecision
    let mode: PlanSheetMode
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
                    Button(plan.operation == .remove ? "Confirm Removal" : "Confirm Update", role: plan.operation == .remove ? .destructive : nil) {
                        onConfirm(plan)
                    }
                    // Deliberately no Return/default shortcut for a destructive action.
                    .accessibilityHint("Runs the reviewed operation for this exact installation.")
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .interactiveDismissDisabled(isExecuting)
        .onAppear { cancelFocused = true }
    }

    @ViewBuilder private func review(_ plan: ActionPlan) -> some View {
        Label(plan.operation == .remove ? "Review Removal" : "Review Update", systemImage: plan.operation == .remove ? "trash" : "arrow.down.circle")
            .font(.title2.weight(.semibold))
        Text("AppHarbor will re-check the target and manager immediately before starting.")
            .font(.callout).foregroundStyle(.secondary)
        GroupBox("Exact target") {
            VStack(alignment: .leading, spacing: 5) {
                Text(plan.installationID.nativeID).font(.headline)
                Text("Location: \(plan.installationID.canonicalLocation)")
                Text("Scope: \(plan.installationID.scopeID)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        GroupBox("Command") {
            HStack(alignment: .top, spacing: 10) {
                Text(reviewCommand(plan))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reviewCommand(plan), forType: .string)
                } label: { Label("Copy Command", systemImage: "doc.on.doc") }
                    .labelStyle(.iconOnly)
                    .help("Copy complete command to clipboard")
                    .accessibilityLabel("Copy Command")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        Text("AppHarbor cannot undo this operation.")
            .font(.callout.weight(.medium))
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

private func reviewCommand(_ plan: ActionPlan) -> String {
    plan.previewCommand
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
