import AppKit
import AppHarborCore
import AppHarborMCPBridge
import Foundation

extension LibraryModel {
    var mcpHelperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/AppHarborMCP", isDirectory: false)
            .path
    }

    var isMCPHelperAvailable: Bool { FileManager.default.isExecutableFile(atPath: mcpHelperPath) }

    var mcpConfigurationJSON: String {
        let configuration: [String: Any] = [
            "mcpServers": [
                "appharbor": ["command": mcpHelperPath]
            ]
        ]
        guard JSONSerialization.isValidJSONObject(configuration),
              let data = try? JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    func startMCPBridge() {
        guard mcpBridgeEnabled, mcpServer == nil else { return }
        mcpBridgeGeneration &+= 1
        let server = injectedMCPServer ?? MCPBridgeServer()
        let bridgeGeneration = mcpBridgeGeneration
        do {
            try server.start { [weak self] request in
                guard let self else { return MCPAppResponse.error("AppHarbor is unavailable.") }
                return await self.handleMCPRequest(request, bridgeGeneration: bridgeGeneration)
            }
            mcpServer = server
            mcpBridgeStatus = "Running locally while AppHarbor is open"
        } catch {
            mcpServer = nil
            mcpBridgeStatus = "Could not start. Close other AppHarbor instances, then retry."
        }
    }

    func retryMCPBridge() { startMCPBridge() }

    func stopMCPBridge() {
        mcpBridgeGeneration &+= 1
        mcpServer?.stop()
        mcpServer = nil
        mcpBridgeStatus = "Off"
    }

    func copyMCPConfiguration() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mcpConfigurationJSON, forType: .string)
    }

    func handleMCPRequest(_ request: MCPBridgeRequest, bridgeGeneration: Int? = nil) async -> MCPBridgeResponse {
        guard mcpBridgeEnabled,
              bridgeGeneration == nil || bridgeGeneration == mcpBridgeGeneration else {
            return MCPAppResponse.error("The local AppHarbor bridge is turned off or has been restarted.")
        }
        do { try MCPBridgeRequestValidator.validate(request) }
        catch { return MCPAppResponse.error("The request parameters are invalid.") }

        switch request.action {
        case .listInstallations:
            return listMCPInstallations(parameters: request.parameters)
        case .listSources:
            return listMCPSources()
        case .getInstallation:
            return getMCPInstallation(identifier: request.parameters["installation_id"] ?? "")
        case .refreshInventory:
            return refreshMCPInventory()
        case .requestRemoval:
            return startMCPActionRequest(request, operation: .remove)
        case .requestUpdate:
            return startMCPActionRequest(request, operation: .update)
        case .getRequestStatus:
            return getMCPRequestStatus(requestID: request.parameters["request_id"] ?? "")
        }
    }

    func planDecisionSheetDidPresent() {
        guard planDecision != nil else { return }
        presentedPlanSheetToken = planDecisionPresentationToken
        presentedPlanSheetMCPRequestID = activeMCPReview?.requestID
    }

    func planDecisionSheetDidDismiss() {
        guard !pendingPlanSheetDismissals.isEmpty else { return }
        let dismissed = pendingPlanSheetDismissals.removeFirst()
        planDecisionSheetDismissalPending = !pendingPlanSheetDismissals.isEmpty
        guard let requestID = dismissed.mcpRequestID,
              activeMCPReview?.requestID == requestID else { return }
        expirePendingMCPReviewIfNeeded()
        guard let review = activeMCPReview, review.requestID == requestID else { return }
        if let record = mcpRequestRecords[requestID],
           record.status == .preparing || record.status == .awaitingConfirmation {
            updateMCPRequest(requestID, status: .declined, message: "The review was closed without confirmation.")
        }
        activeMCPReview = nil
        mcpExpiryTask?.cancel()
        mcpExpiryTask = nil
    }

    func execute(_ plan: ActionPlan) async {
        guard !isPreparingPlan, !isExecutingOperation,
              case let .ready(currentPlan)? = planDecision,
              currentPlan.id == plan.id else {
            return
        }
        var executingMCPRequestID: String?
        // Capture provenance before pruning. An expired MCP plan must still be
        // recognized as MCP-originated so it cannot fall through to the normal
        // native-plan execution path if the expiry task has not run yet.
        let provenance = mcpPlanProvenance[plan.id]
        pruneMCPPlanProvenance()
        if let provenance {
            expirePendingMCPReviewIfNeeded()
            guard mcpBridgeEnabled, mcpActionRequestsEnabled,
                  let active = activeMCPReview,
                  active.requestID == provenance.requestID,
                  active.planID == plan.id,
                  active.installationID == plan.installationID,
                  active.operation == plan.operation,
                  active.expiresAt > .now,
                  plan.expiresAt > .now else {
                if mcpRequestRecords[provenance.requestID]?.status == .awaitingConfirmation {
                    updateMCPRequest(provenance.requestID, status: .invalidated,
                                     message: "This review expired or lost its AppHarbor context. Request a new review.")
                }
                if activeMCPReview?.requestID == provenance.requestID {
                    activeMCPReview = nil
                    mcpExpiryTask?.cancel()
                    mcpExpiryTask = nil
                }
                if case let .ready(current)? = planDecision, current.id == plan.id { planDecision = nil }
                return
            }
            activeMCPReview = nil
            executingMCPRequestID = provenance.requestID
            mcpExpiryTask?.cancel()
            mcpExpiryTask = nil
            updateMCPRequest(provenance.requestID, status: .running, message: "AppHarbor is running the confirmed operation and verifying its result.")
        }

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
        if let requestID = executingMCPRequestID {
            switch record.state {
            case .succeeded: updateMCPRequest(requestID, status: .succeeded, message: "The owning source confirmed the change.", verification: record.verification)
            case .failed: updateMCPRequest(requestID, status: .failed, message: "The action did not complete. Check the item in AppHarbor before retrying.", verification: record.verification)
            case .outcomeUnknown, .running, .verifying: updateMCPRequest(requestID, status: .outcomeUnknown, message: "AppHarbor could not confirm the final result. Check the item before retrying.", verification: record.verification)
            case .invalidated: updateMCPRequest(requestID, status: .invalidated, message: "The target changed or the operation was rejected before launch.", verification: record.verification)
            case .awaitingConfirmation: updateMCPRequest(requestID, status: .invalidated, message: "The operation was not confirmed.", verification: record.verification)
            }
        }
    }

    func expirePendingMCPReviewIfNeeded(now: Date = .now) {
        guard let review = activeMCPReview, review.expiresAt <= now else { return }
        if let status = mcpRequestRecords[review.requestID]?.status,
           status == .preparing || status == .awaitingConfirmation {
            updateMCPRequest(review.requestID, status: .invalidated, message: "The review expired. Request a new review in AppHarbor.")
        }
        activeMCPReview = nil
        mcpExpiryTask?.cancel()
        mcpExpiryTask = nil
        if planDecision != nil { planDecision = nil }
    }

    func invalidatePendingMCPReview(message: String) {
        guard let review = activeMCPReview else { return }
        if let record = mcpRequestRecords[review.requestID], record.status != .running {
            updateMCPRequest(review.requestID, status: .invalidated, message: message)
        }
        activeMCPReview = nil
        mcpExpiryTask?.cancel()
        mcpExpiryTask = nil
        if planDecision != nil { planDecision = nil }
    }

    private func listMCPInstallations(parameters: [String: String]) -> MCPBridgeResponse {
        let offset = Int(parameters["offset"] ?? "0") ?? 0
        let limit = Int(parameters["limit"] ?? "25") ?? 25
        let query = parameters["query"] ?? ""
        guard query.count <= 256 else { return MCPAppResponse.error("The search query must be 256 characters or fewer.") }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = installations.filter { item in
            normalizedQuery.isEmpty || [item.displayName, item.version ?? "", item.canonicalLocation, item.kind.rawValue,
                                         managerLabelForMCP(item.identity.managerID)]
                .contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
        }
        let page = Array(matching.dropFirst(offset).prefix(limit))
        let items = page.map(mcpInstallationObject)
        return MCPAppResponse.make([
            "items": items,
            "total": matching.count,
            "offset": offset,
            "limit": limit,
            "is_refreshing": isRefreshing,
            "stale_count": matching.filter(\.isStale).count,
            "refreshed_at": snapshot.map { ISO8601DateFormatter().string(from: $0.refreshedAt) } as Any? ?? NSNull()
        ])
    }

    private func listMCPSources() -> MCPBridgeResponse {
        let sources = managers.map { manager -> [String: Any] in
            let sourceCoverage = coverage.first { $0.id == manager.id }
            return [
                "source": mcpSourceName(manager.kind),
                "presence": manager.presence.rawValue,
                "scope": MCPAppResponse.safeText(manager.scope.canonicalRoot ?? manager.scope.displayName),
                "installation_count": installations.filter { $0.identity.managerID == manager.id }.count,
                "coverage": sourceCoverage?.state.rawValue ?? "unknown"
            ]
        }
        let coverageSummary = coverage.map { value in
            ["source": MCPAppResponse.safeText(value.sourceName),
             "scope": MCPAppResponse.safeText(value.scopeID),
             "state": value.state.rawValue,
             "installation_count": value.itemCount] as [String: Any]
        }
        return MCPAppResponse.make(["sources": sources, "coverage": coverageSummary, "is_refreshing": isRefreshing])
    }

    private func getMCPInstallation(identifier: String) -> MCPBridgeResponse {
        guard let item = installations.first(where: { MCPInventoryPresenter.identifier(for: $0.identity) == identifier }) else {
            return MCPAppResponse.error("That installation is not in the current inventory.")
        }
        return MCPAppResponse.make(["installation": mcpInstallationObject(item), "is_refreshing": isRefreshing])
    }

    private func refreshMCPInventory() -> MCPBridgeResponse {
        if isRefreshing { return MCPAppResponse.make(["status": "already_running", "is_refreshing": true]) }
        guard !isExecutingOperation, !isPreparingPlan, planDecision == nil,
              !planDecisionSheetDismissalPending, activeMCPReview == nil else {
            return MCPAppResponse.error("AppHarbor is busy with another operation or review. Try again shortly.")
        }
        isRefreshing = true
        Task { [weak self] in await self?.refresh(reservationAlreadySet: true) }
        mcpLatestRequestStatus = "Inventory refresh requested"
        return MCPAppResponse.make(["status": "refresh_started", "is_refreshing": true])
    }

    private func startMCPActionRequest(_ request: MCPBridgeRequest, operation: ManagedOperation) -> MCPBridgeResponse {
        guard mcpActionRequestsEnabled else { return MCPAppResponse.error("AI action requests are turned off in AppHarbor Settings.") }
        let requestID = (request.parameters["request_id"] ?? "").lowercased()
        let installationIdentifier = request.parameters["installation_id"] ?? ""
        let fingerprint = "\(request.action.rawValue)|\(installationIdentifier)"
        pruneMCPRequestRecords()
        if let previous = mcpRequestRecords[requestID] {
            guard previous.payloadFingerprint == fingerprint else { return MCPAppResponse.error("This request_id was already used for a different action or installation.") }
            return mcpRequestResponse(previous)
        }
        guard !isRefreshing, !isPreparingPlan, !isExecutingOperation, planDecision == nil,
              !planDecisionSheetDismissalPending, activeMCPReview == nil else {
            return MCPAppResponse.error("AppHarbor is busy. Finish the current review or operation before requesting another.")
        }
        pruneMCPPlanProvenance()
        guard mcpPlanProvenance.count < 100 else {
            return MCPAppResponse.error("AppHarbor has 100 recent AI review plans that have not expired. Wait briefly, then try again.")
        }
        guard let item = installations.first(where: { MCPInventoryPresenter.identifier(for: $0.identity) == installationIdentifier }) else {
            return MCPAppResponse.error("That installation is not in the current inventory.")
        }
        guard let engine else { return MCPAppResponse.error("The AppHarbor inventory engine is unavailable.") }

        let now = Date()
        let record = MCPRequestRecord(requestID: requestID, payloadFingerprint: fingerprint, operation: operation,
                                      installationID: item.identity, status: .preparing,
                                      message: "AppHarbor is preparing a review for \(MCPAppResponse.safeText(item.displayName)).",
                                      verification: nil,
                                      createdAt: now, updatedAt: now)
        storeMCPRequest(record)
        activeMCPReview = PendingMCPReview(requestID: requestID, payloadFingerprint: fingerprint, operation: operation,
                                           installationID: item.identity, displayName: MCPAppResponse.safeText(item.displayName),
                                           planID: nil, expiresAt: now.addingTimeInterval(mcpReviewTTL))
        scheduleMCPReviewExpiry(requestID: requestID)
        isPreparingPlan = true
        let generation = mcpConfigurationGeneration
        Task { [weak self] in
            await self?.prepareMCPAction(requestID: requestID, generation: generation, operation: operation, item: item, engine: engine)
        }
        return MCPAppResponse.make(["request_id": requestID, "status": "preparing", "message": "AppHarbor will show this request for review."])
    }

    private func prepareMCPAction(requestID: String, generation: Int, operation: ManagedOperation,
                                  item: Installation, engine: AppHarborCoreEngine) async {
        let decision = await engine.prepare(operation: operation, installationID: item.identity)
        isPreparingPlan = false
        guard generation == mcpConfigurationGeneration, mcpBridgeEnabled, mcpActionRequestsEnabled,
              activeMCPReview?.requestID == requestID,
              mcpRequestRecords[requestID]?.status == .preparing else { return }
        guard let review = activeMCPReview, review.expiresAt > .now else {
            expirePendingMCPReviewIfNeeded()
            return
        }

        planSheetMode = .review
        switch decision {
        case .ready(let plan):
            let reviewExpiry = min(review.expiresAt, plan.expiresAt)
            activeMCPReview?.planID = plan.id
            activeMCPReview?.expiresAt = reviewExpiry
            mcpPlanProvenance[plan.id] = MCPPlanProvenance(requestID: requestID, expiresAt: plan.expiresAt)
            mcpPlanProvenanceOrder.append(plan.id)
            updateMCPRequest(requestID, status: .awaitingConfirmation, message: "Review and confirm this exact action in AppHarbor.")
        case .guidance:
            updateMCPRequest(requestID, status: .guidance, message: "This installation needs manual guidance; AppHarbor will not run an action for it.")
        case .blocked:
            updateMCPRequest(requestID, status: .blocked, message: "AppHarbor cannot prepare a verified action for this installation.")
        }
        planDecision = decision
        scheduleMCPReviewExpiry(requestID: requestID)
    }

    private func getMCPRequestStatus(requestID: String) -> MCPBridgeResponse {
        pruneMCPRequestRecords()
        expirePendingMCPReviewIfNeeded()
        guard let record = mcpRequestRecords[requestID.lowercased()] else {
            return MCPAppResponse.error("No in-memory request with that request_id was found. Requests expire after 30 minutes and when AppHarbor quits.")
        }
        return mcpRequestResponse(record)
    }

    private func mcpRequestResponse(_ record: MCPRequestRecord) -> MCPBridgeResponse {
        var payload: [String: Any] = ["request_id": record.requestID, "status": record.status.rawValue,
                                      "message": MCPAppResponse.safeText(record.message)]
        if let verification = record.verification { payload["verification"] = verification.rawValue }
        return MCPAppResponse.make(payload)
    }

    private func storeMCPRequest(_ record: MCPRequestRecord) {
        mcpRequestRecords[record.requestID] = record
        mcpRequestOrder.removeAll { $0 == record.requestID }
        mcpRequestOrder.append(record.requestID)
        mcpLatestRequestStatus = "\(record.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) · \(record.message)"
        pruneMCPRequestRecords()
    }

    private func updateMCPRequest(_ requestID: String, status: MCPRequestStatus, message: String,
                                  verification: VerificationResult? = nil) {
        guard var record = mcpRequestRecords[requestID] else { return }
        record.status = status
        record.message = message
        record.verification = verification
        record.updatedAt = .now
        storeMCPRequest(record)
    }

    private func pruneMCPRequestRecords(now: Date = .now) {
        pruneMCPPlanProvenance(now: now)
        let cutoff = now.addingTimeInterval(-30 * 60)
        for id in mcpRequestOrder where mcpRequestRecords[id]?.createdAt ?? .distantPast < cutoff {
            mcpRequestRecords.removeValue(forKey: id)
        }
        mcpRequestOrder.removeAll { mcpRequestRecords[$0] == nil }
        while mcpRequestOrder.count > 100 {
            let oldest = mcpRequestOrder.removeFirst()
            if activeMCPReview?.requestID != oldest { mcpRequestRecords.removeValue(forKey: oldest) }
        }
    }

    private func pruneMCPPlanProvenance(now: Date = .now) {
        for id in mcpPlanProvenanceOrder where (mcpPlanProvenance[id]?.expiresAt ?? .distantPast) <= now {
            mcpPlanProvenance.removeValue(forKey: id)
        }
        mcpPlanProvenanceOrder.removeAll { mcpPlanProvenance[$0] == nil }
    }

    private func scheduleMCPReviewExpiry(requestID: String) {
        mcpExpiryTask?.cancel()
        let delay = max(0, activeMCPReview?.expiresAt.timeIntervalSinceNow ?? 0)
        let nanoseconds = UInt64(min(delay, 300) * 1_000_000_000)
        mcpExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, self.activeMCPReview?.requestID == requestID else { return }
            self.expirePendingMCPReviewIfNeeded()
        }
    }

    private func mcpInstallationObject(_ item: Installation) -> [String: Any] {
        let manager = managers.first { $0.id == item.identity.managerID }
        return [
            "installation_id": MCPInventoryPresenter.identifier(for: item.identity),
            "display_name": MCPAppResponse.safeText(item.displayName),
            "version": item.version.map(MCPAppResponse.safeText) as Any? ?? NSNull(),
            "kind": item.kind.rawValue,
            "source": manager.map { mcpSourceName($0.kind) } ?? "Unknown",
            "scope": manager.map { MCPAppResponse.safeText($0.scope.canonicalRoot ?? $0.scope.displayName) } ?? MCPAppResponse.safeText(item.identity.scopeID),
            "path": MCPAppResponse.safeText(item.canonicalLocation),
            "ownership": item.ownership.rawValue,
            "stale": item.isStale,
            "protected": item.isProtected,
            "removal_supported": item.removalSupported,
            "update_supported": item.updateSupported
        ]
    }

    private func managerLabelForMCP(_ id: String) -> String {
        managers.first { $0.id == id }.map { mcpSourceName($0.kind) } ?? "Unknown"
    }

    private func mcpSourceName(_ kind: ManagerKind) -> String {
        switch kind {
        case .appBundle: "Applications"
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .pipx: "pipx"
        case .cargo: "Cargo"
        case .other: "Other"
        }
    }
}
