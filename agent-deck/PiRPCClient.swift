import Foundation

final class PiRPCClient: @unchecked Sendable {
    typealias EventHandler = @Sendable (_ rawLine: String, _ event: PiAgentRPCEvent?) -> Void
    typealias StderrHandler = @Sendable (_ line: String) -> Void
    typealias TerminationHandler = @Sendable (_ exitCode: Int32) -> Void

    private let process: PiAgentProcess
    private let encoder = JSONEncoder()
    private var requestCounter = 0
    private let lock = NSLock()

    var launchCommand: String { process.launchCommand }
    var isRunning: Bool { process.isRunning }

    init(
        cwd: URL,
        sessionFile: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        modelArgument: String? = nil,
        extraArguments: [String] = [],
        environment: [String: String] = [:],
        onEvent: @escaping EventHandler,
        onStderr: @escaping StderrHandler,
        onTermination: @escaping TerminationHandler
    ) throws {
        let args = Self.launchArguments(
            sessionFile: sessionFile,
            provider: provider,
            model: model,
            modelArgument: modelArgument,
            extraArguments: extraArguments
        )

        process = try PiAgentProcess(
            configuration: .init(arguments: args, currentDirectoryURL: cwd, environment: environment),
            onStdoutLine: { line in
                let data = Data(line.utf8)
                let event = try? JSONDecoder().decode(PiAgentRPCEvent.self, from: data)
                onEvent(line, event)
            },
            onStderrLine: onStderr,
            onTermination: onTermination
        )
    }

    static func launchArguments(
        sessionFile: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        modelArgument: String? = nil,
        extraArguments: [String] = []
    ) -> [String] {
        var args = ["--mode", "rpc"]
        args.append(contentsOf: extraArguments)
        if let sessionFile, !sessionFile.isEmpty {
            args.append(contentsOf: ["--session", sessionFile])
        }
        if let provider, !provider.isEmpty {
            args.append(contentsOf: ["--provider", provider])
        }
        if let modelArgument, !modelArgument.isEmpty {
            args.append(contentsOf: ["--model", modelArgument])
        } else if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        return args
    }

    func getState() { send(type: "get_state") }
    func getMessages() { send(type: "get_messages") }
    func getSessionStats() { send(type: "get_session_stats") }
    func getAvailableModels() { send(type: "get_available_models") }
    func abort() { send(type: "abort") }
    func setSessionName(_ name: String) { send(type: "set_session_name", fields: ["name": name]) }
    func setModel(provider: String, modelID: String) { send(type: "set_model", fields: ["provider": provider, "modelId": modelID]) }
    func cycleModel() { send(type: "cycle_model") }
    func setThinkingLevel(_ level: String) { send(type: "set_thinking_level", fields: ["level": level]) }
    func cycleThinkingLevel() { send(type: "cycle_thinking_level") }
    func compact(customInstructions: String? = nil) {
        var fields: [String: Any] = [:]
        if let customInstructions, !customInstructions.isEmpty {
            fields["customInstructions"] = customInstructions
        }
        send(type: "compact", fields: fields)
    }
    func prompt(_ message: String, images: [PiAgentImageAttachment] = [], streamingBehavior: String? = nil) {
        sendUserMessage(type: "prompt", message: message, images: images, streamingBehavior: streamingBehavior)
    }
    func steer(_ message: String, images: [PiAgentImageAttachment] = []) { sendUserMessage(type: "steer", message: message, images: images) }
    func followUp(_ message: String, images: [PiAgentImageAttachment] = []) { sendUserMessage(type: "follow_up", message: message, images: images) }
    func respondToExtensionUI(id: String, value: String) { sendExtensionUIResponse(["id": id, "value": value]) }
    func confirmExtensionUI(id: String, confirmed: Bool) { sendExtensionUIResponse(["id": id, "confirmed": confirmed]) }
    func cancelExtensionUI(id: String) { sendExtensionUIResponse(["id": id, "cancelled": true]) }

    private func sendUserMessage(type: String, message: String, images: [PiAgentImageAttachment], streamingBehavior: String? = nil) {
        var fields: [String: Any] = ["message": message]
        if let streamingBehavior {
            fields["streamingBehavior"] = streamingBehavior
        }
        if !images.isEmpty {
            fields["images"] = images.map(\.rpcPayload)
        }
        send(type: type, fields: fields)
    }

    func send(type: String, fields: [String: Any] = [:]) {
        lock.lock()
        requestCounter += 1
        let requestID = "pm-\(requestCounter)"
        lock.unlock()

        var command = fields
        command["id"] = requestID
        command["type"] = type
        write(command)
    }

    private func sendExtensionUIResponse(_ fields: [String: Any]) {
        var command = fields
        command["type"] = "extension_ui_response"
        write(command)
    }

    private func write(_ command: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(command),
              let data = try? JSONSerialization.data(withJSONObject: command),
              let line = String(data: data, encoding: .utf8) else { return }
        process.writeJSONLine(line)
    }

    func stop() {
        abort()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [process] in
            process.terminate()
        }
    }
}
