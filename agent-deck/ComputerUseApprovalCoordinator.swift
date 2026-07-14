import Foundation
import Observation

/// Main-actor owner for Computer Use approvals. Elicitation is deliberately
/// one-call only; app-control grants are separate, memory-only capabilities.
@MainActor
@Observable
final class ComputerUseApprovalCoordinator {
    enum State: String, Sendable { case pending, accepted, declined, cancelled, expired }
    enum RequestKind: String, Sendable, Hashable { case serviceElicitation, controlApp }

    enum RequesterIdentity: Sendable, Hashable {
        case projectParent
        case boundAgent(name: String)
        case delegatedChild(runID: UUID, name: String)

        init(context: MCPCallContext) {
            if let runID = context.subagentRunID {
                self = .delegatedChild(runID: runID, name: Self.sanitizedName(context.requestingAgent) ?? "Unnamed child")
            } else if let name = Self.sanitizedName(context.requestingAgent) {
                self = .boundAgent(name: name)
            } else {
                self = .projectParent
            }
        }

        private static func sanitizedName(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { ($0.value < 0x20 || $0.value == 0x7F) }) else { return nil }
            return trimmed.precomposedStringWithCanonicalMapping
        }

        var displayName: String {
            switch self {
            case .projectParent: "Parent session"
            case let .boundAgent(name): "Bound agent: \(name)"
            case let .delegatedChild(runID, name): "Delegated child: \(name) (\(runID.uuidString))"
            }
        }
    }

    struct GrantKey: Sendable, Hashable {
        let sessionID: UUID
        let requester: RequesterIdentity
        let appTarget: String
    }

    enum ControlDenyReason: Error, Sendable, Hashable {
        case invalidArguments
        case missingApp
        case nonStringApp
        case appTooLong
        case appContainsControlCharacters
        case uiUnavailable
        case sessionNotLive
        case declined
        case cancelled
        case expired
    }

    enum ControlAuthorization: Sendable, Hashable {
        case authorized
        case denied(ControlDenyReason)
    }

    struct Request: Identifiable, Sendable, Hashable {
        let id: UUID
        let kind: RequestKind
        let serverRequestID: RPCID?
        let server: String
        let tool: String
        let projectID: String?
        let sessionID: UUID
        let requestingAgent: String?
        let subagentRunID: UUID?
        let requester: RequesterIdentity
        let appTarget: String?
        let title: String?
        let message: String
        let schemaSummary: String
        let advertisedPersistenceModes: Set<MCPElicitationMeta.PersistenceMode>
        let deadline: Date
        let state: State
    }

    private enum PendingResult: Sendable {
        case elicitation(MCPServerRequestDisposition)
        case control(ControlAuthorization)
    }

    private struct Pending {
        var request: Request
        var waiters: [UUID: CheckedContinuation<PendingResult, Never>]
        var timeout: Task<Void, Never>?
        let grantKey: GrantKey?
    }

    private var pending: [UUID: Pending] = [:]
    private var queues: [UUID: [UUID]] = [:]
    private var pendingByGrantKey: [GrantKey: UUID] = [:]
    private var grants: Set<GrantKey> = []
    private(set) var isUIServicingRequests = false
    private let timeout: TimeInterval
    private static let maximumAppTargetLength = 1_024

    init(timeout: TimeInterval = 60) { self.timeout = timeout }

    func setUIServicingRequests(_ available: Bool) {
        isUIServicingRequests = available
        if !available { resolveAll(as: .cancelled) }
    }

    func request(for sessionID: UUID?) -> Request? {
        guard let sessionID, let id = queues[sessionID]?.first else { return nil }
        return pending[id]?.request
    }

    func hasGrant(_ key: GrantKey) -> Bool { grants.contains(key) }
    func hasGrant(appArguments: JSONValue?, context: MCPCallContext) -> Bool {
        guard case let .success(key) = grantKey(arguments: appArguments, context: context) else { return false }
        return hasGrant(key)
    }

    /// Authorization entry point for future action tools. It intentionally is not
    /// connected to the MCP policy/catalog during Phase 4A.
    func authorize(appArguments: JSONValue?, context: MCPCallContext, sessionIsLive: Bool) async -> ControlAuthorization {
        switch grantKey(arguments: appArguments, context: context) {
        case let .failure(reason): return .denied(reason)
        case let .success(key):
            guard sessionIsLive else { return .denied(.sessionNotLive) }
            guard isUIServicingRequests else { return .denied(.uiUnavailable) }
            if grants.contains(key) { return .authorized }
            return await enqueueControl(key: key, context: context)
        }
    }

    func enqueue(_ elicitation: MCPElicitationRequest, context: MCPCallContext, sessionIsLive: Bool) async -> MCPServerRequestDisposition {
        guard isUIServicingRequests, sessionIsLive, elicitation.isConfirmationOnly else {
            return .result(MCPRequestFactory.elicitationResponse(action: "decline"))
        }
        let requestID = UUID()
        let waiterID = UUID()
        let result: PendingResult = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .elicitation(.result(MCPRequestFactory.elicitationResponse(action: "cancel"))))
                    return
                }
                let request = Request(
                    id: requestID, kind: .serviceElicitation, serverRequestID: elicitation.id, server: context.server, tool: context.tool,
                    projectID: context.projectID, sessionID: context.sessionID, requestingAgent: context.requestingAgent, subagentRunID: context.subagentRunID,
                    requester: RequesterIdentity(context: context), appTarget: nil, title: Self.sanitizedPlainText(elicitation.title),
                    message: Self.sanitizedPlainText(elicitation.message ?? "") ?? "[redacted]",
                    schemaSummary: "Confirmation only — no information will be entered.", advertisedPersistenceModes: elicitation.meta.persistenceModes,
                    deadline: Date().addingTimeInterval(timeout), state: .pending
                )
                insert(request: request, waiterID: waiterID, continuation: continuation, grantKey: nil)
            }
        }, onCancel: { [weak self] in Task { @MainActor [weak self] in self?.resolveWaiter(requestID: requestID, waiterID: waiterID, as: .cancelled) } })
        if case let .elicitation(disposition) = result { return disposition }
        return .result(MCPRequestFactory.elicitationResponse(action: "decline"))
    }

    func accept(_ request: Request) { resolve(request.id, as: .accepted) }
    func decline(_ request: Request) { resolve(request.id, as: .declined) }
    func cancel(_ request: Request) { resolve(request.id, as: .cancelled) }
    func cancel(sessionID: UUID) { for id in queues[sessionID] ?? [] { resolve(id, as: .cancelled) } }
    func cancel(subagentRunID: UUID) { for (id, item) in pending where item.request.subagentRunID == subagentRunID { resolve(id, as: .cancelled) } }

    func revoke(sessionID: UUID) {
        grants = grants.filter { $0.sessionID != sessionID }
        cancel(sessionID: sessionID)
    }

    func revoke(subagentRunID: UUID) {
        grants = grants.filter {
            if case let .delegatedChild(runID, _) = $0.requester { return runID != subagentRunID }
            return true
        }
        cancel(subagentRunID: subagentRunID)
    }

    func revokeAll() {
        grants.removeAll()
        resolveAll()
    }

    func resolveAll(as state: State = .cancelled) { for id in Array(pending.keys) { resolve(id, as: state) } }

    private func enqueueControl(key: GrantKey, context: MCPCallContext) async -> ControlAuthorization {
        let waiterID = UUID()
        let requestID = pendingByGrantKey[key] ?? UUID()
        let result: PendingResult = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .control(.denied(.cancelled))); return }
                if let existingID = pendingByGrantKey[key], var item = pending[existingID] {
                    item.waiters[waiterID] = continuation
                    pending[existingID] = item
                    return
                }
                let request = Request(
                    id: requestID, kind: .controlApp, serverRequestID: nil, server: context.server, tool: context.tool,
                    projectID: context.projectID, sessionID: context.sessionID, requestingAgent: context.requestingAgent, subagentRunID: context.subagentRunID,
                    requester: key.requester, appTarget: key.appTarget, title: "Allow control for this session",
                    message: "Allow \(key.requester.displayName) to control \(key.appTarget)?", schemaSummary: "This grants app control only to this requester for the current session.",
                    advertisedPersistenceModes: [], deadline: Date().addingTimeInterval(timeout), state: .pending
                )
                insert(request: request, waiterID: waiterID, continuation: continuation, grantKey: key)
            }
        }, onCancel: { [weak self] in Task { @MainActor [weak self] in self?.resolveWaiter(requestID: requestID, waiterID: waiterID, as: .cancelled) } })
        if case let .control(authorization) = result { return authorization }
        return .denied(.cancelled)
    }

    private func insert(request: Request, waiterID: UUID, continuation: CheckedContinuation<PendingResult, Never>, grantKey: GrantKey?) {
        pending[request.id] = Pending(request: request, waiters: [waiterID: continuation], timeout: nil, grantKey: grantKey)
        queues[request.sessionID, default: []].append(request.id)
        if let grantKey { pendingByGrantKey[grantKey] = request.id }
        pending[request.id]?.timeout = Task { [weak self, timeout = self.timeout] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.resolve(request.id, as: .expired)
        }
    }

    private func resolveWaiter(requestID: UUID, waiterID: UUID, as state: State) {
        guard var item = pending[requestID], let continuation = item.waiters.removeValue(forKey: waiterID) else { return }
        if item.waiters.isEmpty {
            pending.removeValue(forKey: requestID)
            item.timeout?.cancel()
            if let key = item.grantKey { pendingByGrantKey[key] = nil }
            queues[item.request.sessionID]?.removeAll { $0 == requestID }
            if queues[item.request.sessionID]?.isEmpty == true { queues[item.request.sessionID] = nil }
        } else {
            pending[requestID] = item
        }
        continuation.resume(returning: result(for: item.request, state: state))
    }

    private func resolve(_ id: UUID, as state: State) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.timeout?.cancel()
        if let key = item.grantKey {
            pendingByGrantKey[key] = nil
            if state == .accepted { grants.insert(key) }
        }
        queues[item.request.sessionID]?.removeAll { $0 == id }
        if queues[item.request.sessionID]?.isEmpty == true { queues[item.request.sessionID] = nil }
        let terminal = result(for: item.request, state: state)
        for continuation in item.waiters.values { continuation.resume(returning: terminal) }
    }

    private func result(for request: Request, state: State) -> PendingResult {
        switch request.kind {
        case .serviceElicitation:
            return .elicitation(.result(MCPRequestFactory.elicitationResponse(action: state == .accepted ? "accept" : state == .cancelled || state == .expired ? "cancel" : "decline")))
        case .controlApp:
            return .control(state == .accepted ? .authorized : .denied(state == .declined ? .declined : state == .expired ? .expired : .cancelled))
        }
    }

    private func grantKey(arguments: JSONValue?, context: MCPCallContext) -> Result<GrantKey, ControlDenyReason> {
        guard case let .object(object)? = arguments else { return .failure(.invalidArguments) }
        guard let app = object["app"] else { return .failure(.missingApp) }
        guard case let .string(raw) = app else { return .failure(.nonStringApp) }
        guard raw.count <= Self.maximumAppTargetLength else { return .failure(.appTooLong) }
        guard !raw.unicodeScalars.contains(where: { ($0.value < 0x20 || $0.value == 0x7F) }) else { return .failure(.appContainsControlCharacters) }
        let normalized = normalizeAppTarget(raw)
        guard !normalized.isEmpty else { return .failure(.missingApp) }
        return .success(GrantKey(sessionID: context.sessionID, requester: RequesterIdentity(context: context), appTarget: normalized))
    }

    private func normalizeAppTarget(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        if value.hasPrefix("/"), value.lowercased().hasSuffix(".app") {
            return (value as NSString).standardizingPath.precomposedStringWithCanonicalMapping.lowercased()
        }
        if value.lowercased().hasSuffix(".app") { return value.lowercased() }
        // Bundle identifiers are normalized, but arbitrary display names are not
        // treated as aliases or expanded to bundle IDs.
        if value.contains("."), !value.contains("/") { return value.lowercased() }
        return value
    }

    private static func sanitizedPlainText(_ value: String?) -> String? {
        guard let value else { return nil }
        let clipped = String(value.prefix(4_000))
        let tokens = clipped.split(whereSeparator: { $0.isWhitespace })
        return tokens.map { token in
            let text = String(token)
            let base64ish = text.count >= 32 && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" || $0 == "-" || $0 == "_" }
            return base64ish ? "[redacted]" : text
        }.joined(separator: " ")
    }
}
