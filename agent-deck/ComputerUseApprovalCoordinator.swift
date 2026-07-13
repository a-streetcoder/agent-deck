import Foundation
import Observation

/// Main-actor owner for the deliberately narrow Computer Use MCP approval flow.
/// Requests are kept only in memory until one terminal response is sent.
@MainActor
@Observable
final class ComputerUseApprovalCoordinator {
    enum State: String, Sendable { case pending, accepted, declined, cancelled, expired }

    struct Request: Identifiable, Sendable, Hashable {
        let id: UUID
        let serverRequestID: RPCID
        let server: String
        let tool: String
        let projectID: String?
        let sessionID: UUID
        let requestingAgent: String?
        let subagentRunID: UUID?
        let title: String?
        let message: String
        let schemaSummary: String
        let advertisedPersistenceModes: Set<MCPElicitationMeta.PersistenceMode>
        let deadline: Date
        let state: State
    }

    private struct Pending {
        var request: Request
        let continuation: CheckedContinuation<MCPServerRequestDisposition, Never>
        var timeout: Task<Void, Never>?
    }

    private var pending: [UUID: Pending] = [:]
    private var queues: [UUID: [UUID]] = [:]
    private(set) var isUIServicingRequests = false
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 60) { self.timeout = timeout }

    func setUIServicingRequests(_ available: Bool) {
        isUIServicingRequests = available
        if !available { resolveAll(as: .cancelled) }
    }

    func request(for sessionID: UUID?) -> Request? {
        guard let sessionID, let id = queues[sessionID]?.first else { return nil }
        return pending[id]?.request
    }

    func enqueue(_ elicitation: MCPElicitationRequest, context: MCPCallContext, sessionIsLive: Bool) async -> MCPServerRequestDisposition {
        guard isUIServicingRequests, sessionIsLive, elicitation.isConfirmationOnly else {
            return .result(MCPRequestFactory.elicitationResponse(action: "decline"))
        }
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .result(MCPRequestFactory.elicitationResponse(action: "cancel")))
                    return
                }
                let request = Request(
                    id: id, serverRequestID: elicitation.id, server: context.server, tool: context.tool,
                    projectID: context.projectID, sessionID: context.sessionID,
                    requestingAgent: context.requestingAgent, subagentRunID: context.subagentRunID,
                    title: Self.sanitizedPlainText(elicitation.title), message: Self.sanitizedPlainText(elicitation.message ?? "") ?? "[redacted]",
                    schemaSummary: "Confirmation only — no information will be entered.",
                    advertisedPersistenceModes: elicitation.meta.persistenceModes,
                    deadline: Date().addingTimeInterval(timeout), state: .pending
                )
                pending[id] = Pending(request: request, continuation: continuation)
                queues[context.sessionID, default: []].append(id)
                pending[id]?.timeout = Task { [weak self, timeout = self.timeout] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    self?.resolve(id, as: .expired)
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.resolve(id, as: .cancelled) }
        })
    }

    func accept(_ request: Request) { resolve(request.id, as: .accepted) }
    func decline(_ request: Request) { resolve(request.id, as: .declined) }
    func cancel(_ request: Request) { resolve(request.id, as: .cancelled) }
    func cancel(sessionID: UUID) { for id in queues[sessionID] ?? [] { resolve(id, as: .cancelled) } }
    func cancel(subagentRunID: UUID) {
        for (id, item) in pending where item.request.subagentRunID == subagentRunID { resolve(id, as: .cancelled) }
    }
    func resolveAll(as state: State = .cancelled) { for id in Array(pending.keys) { resolve(id, as: state) } }

    private func resolve(_ id: UUID, as state: State) {
        guard var item = pending.removeValue(forKey: id) else { return }
        item.timeout?.cancel()
        item.request = Request(
            id: item.request.id, serverRequestID: item.request.serverRequestID, server: item.request.server, tool: item.request.tool,
            projectID: item.request.projectID, sessionID: item.request.sessionID, requestingAgent: item.request.requestingAgent,
            subagentRunID: item.request.subagentRunID, title: item.request.title, message: item.request.message,
            schemaSummary: item.request.schemaSummary, advertisedPersistenceModes: item.request.advertisedPersistenceModes,
            deadline: item.request.deadline, state: state
        )
        queues[item.request.sessionID]?.removeAll { $0 == id }
        if queues[item.request.sessionID]?.isEmpty == true { queues[item.request.sessionID] = nil }
        item.continuation.resume(returning: .result(MCPRequestFactory.elicitationResponse(action: state == .accepted ? "accept" : state == .cancelled || state == .expired ? "cancel" : "decline")))
    }

    private static func sanitizedPlainText(_ value: String?) -> String? {
        guard let value else { return nil }
        let clipped = String(value.prefix(4_000))
        // Do not retain likely base64 blobs supplied by a server.
        let tokens = clipped.split(whereSeparator: { $0.isWhitespace })
        return tokens.map { token in
            let text = String(token)
            let base64ish = text.count >= 32 && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" || $0 == "-" || $0 == "_" }
            return base64ish ? "[redacted]" : text
        }.joined(separator: " ")
    }
}
