import Foundation

struct PiNativeSubagentBridgeExtensions {
    static func parentExtensionURL(fileManager: FileManager = .default) throws -> URL {
        try writeExtension(named: "managed-subagent-bridge.ts", content: parentExtensionSource, fileManager: fileManager)
    }

    static func childExtensionURL(fileManager: FileManager = .default) throws -> URL {
        try writeExtension(named: "contact-supervisor-bridge.ts", content: childExtensionSource, fileManager: fileManager)
    }

    private static func writeExtension(named fileName: String, content: String, fileManager: FileManager) throws -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = appSupport
            .appendingPathComponent("Pi Manager", isDirectory: true)
            .appendingPathComponent("Native Subagent Extensions", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        if (try? String(contentsOf: url, encoding: .utf8)) != content {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    private static let parentExtensionSource = """
        import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

        export default function (pi: ExtensionAPI) {
            pi.registerTool({
                name: "managed_subagent",
                description: "Delegate a bounded task to a Pi Manager native subagent. Use this when a specialized subagent can work separately and return a compact result.",
                parameters: {
                    type: "object",
                    properties: {
                        agent: { type: "string", description: "Name of the native subagent to run." },
                        task: { type: "string", description: "Specific task for the subagent." },
                        context: { type: "string", description: "Optional context mode override: fresh or fork." }
                    },
                    required: ["agent", "task"],
                    additionalProperties: false
                },
                promptSnippet: "managed_subagent(agent, task, context?): delegate to a Pi Manager native subagent and get a compact result.",
                promptGuidelines: [
                    "Use managed_subagent for separable specialist work; keep tasks narrow and include expected output.",
                    "Do not call managed_subagent just to continue normal conversation."
                ],
                async execute(toolCallId, params, _signal, onUpdate, ctx) {
                    const payload = JSON.stringify({
                        bridge: "pi_manager_native_subagents",
                        kind: "managed_subagent",
                        toolCallId,
                        agent: String((params as any).agent ?? ""),
                        task: String((params as any).task ?? ""),
                        context: (params as any).context ? String((params as any).context) : undefined
                    });
                    onUpdate?.({ content: [{ type: "text", text: `Starting native subagent ${(params as any).agent}…` }] });
                    const result = await ctx.ui.editor("PI_MANAGER_BRIDGE managed_subagent", payload);
                    return { content: [{ type: "text", text: result || "Native subagent finished without a result." }] };
                }
            });
        }
        """

    private static let childExtensionSource = """
        import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

        export default function (pi: ExtensionAPI) {
            pi.registerTool({
                name: "contact_supervisor",
                description: "Contact the Pi Manager supervisor for progress updates or blocking decisions.",
                parameters: {
                    type: "object",
                    properties: {
                        kind: {
                            type: "string",
                            enum: ["progress_update", "need_decision", "interview_request"],
                            description: "progress_update is non-blocking; need_decision and interview_request block for supervisor response."
                        },
                        message: { type: "string", description: "Message/question for the supervisor." },
                        title: { type: "string", description: "Short title for the supervisor request." }
                    },
                    required: ["kind", "message"],
                    additionalProperties: false
                },
                promptSnippet: "contact_supervisor(kind, message, title?): update or ask the Pi Manager supervisor.",
                promptGuidelines: [
                    "Use progress_update sparingly for meaningful progress.",
                    "Use need_decision only when blocked on a user/product/scope decision.",
                    "Return routine final results normally instead of contacting the supervisor."
                ],
                async execute(toolCallId, params, _signal, _onUpdate, ctx) {
                    const kind = String((params as any).kind ?? "progress_update");
                    const payload = JSON.stringify({
                        bridge: "pi_manager_native_subagents",
                        kind: "contact_supervisor",
                        toolCallId,
                        requestKind: kind,
                        title: (params as any).title ? String((params as any).title) : undefined,
                        message: String((params as any).message ?? ""),
                        runID: process.env.PI_MANAGER_SUBAGENT_RUN_ID,
                        agent: process.env.PI_MANAGER_SUBAGENT_AGENT
                    });
                    const result = await ctx.ui.editor("PI_MANAGER_BRIDGE contact_supervisor", payload);
                    return { content: [{ type: "text", text: result || "Supervisor acknowledged." }] };
                }
            });
        }
        """
}
