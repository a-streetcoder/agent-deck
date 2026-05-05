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
        import { StringEnum } from "@mariozechner/pi-ai";
        import { Type } from "typebox";

        const ManagedSubagentParams = Type.Object({
            agent: Type.String({ description: "Name of the native subagent to run." }),
            task: Type.String({ description: "Specific task for the subagent." }),
            context: Type.Optional(StringEnum(["fresh", "fork"] as const, { description: "Optional context mode override." })),
            reads: Type.Optional(Type.Array(Type.String(), { description: "Project-relative files the subagent should read first if current and relevant." }))
        }, { additionalProperties: false });

        const ManagedChainParams = Type.Object({
            chain: Type.String({ description: "Name of the native chain to run." }),
            task: Type.String({ description: "Initial task available as {task}." }),
            worktree: Type.Optional(Type.Boolean({ description: "Use an isolated worktree for each writer step." }))
        }, { additionalProperties: false });

        const ManagedParallelTask = Type.Object({
            agent: Type.String({ description: "Name of the native subagent to run." }),
            task: Type.String({ description: "Specific bounded task for this subagent." })
        }, { additionalProperties: false });

        const ManagedParallelParams = Type.Object({
            tasks: Type.Array(ManagedParallelTask, { minItems: 1, maxItems: 8, description: "Parallel native subagent tasks." }),
            concurrency: Type.Optional(Type.Number({ minimum: 1, maximum: 8, description: "Maximum child runs at once." })),
            worktree: Type.Optional(Type.Boolean({ description: "Use an isolated worktree per child for writer work." }))
        }, { additionalProperties: false });

        export default function (pi: ExtensionAPI) {
            pi.registerTool({
                name: "managed_subagent",
                description: "Delegate a bounded task to a Pi Manager native subagent. Use this when a specialized subagent can work separately and return a compact result.",
                parameters: ManagedSubagentParams,
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
                        context: (params as any).context ? String((params as any).context) : undefined,
                        reads: Array.isArray((params as any).reads) ? (params as any).reads.map((item: any) => String(item)) : undefined
                    });
                    onUpdate?.({ content: [{ type: "text", text: `Starting native subagent ${(params as any).agent}…` }] });
                    const result = await ctx.ui.editor("PI_MANAGER_BRIDGE managed_subagent", payload);
                    return { content: [{ type: "text", text: result || "Native subagent finished without a result." }] };
                }
            });

            pi.registerTool({
                name: "managed_chain",
                description: "Run a Pi Manager native chain as a supervised sequential workflow.",
                parameters: ManagedChainParams,
                promptSnippet: "managed_chain(chain, task, worktree?): run a native Pi Manager chain and get an aggregate result.",
                promptGuidelines: ["Use managed_chain for multi-step workflows where each step depends on previous output."],
                async execute(toolCallId, params, _signal, onUpdate, ctx) {
                    const payload = JSON.stringify({
                        bridge: "pi_manager_native_subagents",
                        kind: "managed_chain",
                        toolCallId,
                        chain: String((params as any).chain ?? ""),
                        task: String((params as any).task ?? ""),
                        worktree: Boolean((params as any).worktree ?? false)
                    });
                    onUpdate?.({ content: [{ type: "text", text: `Starting native chain ${(params as any).chain}…` }] });
                    const result = await ctx.ui.editor("PI_MANAGER_BRIDGE managed_chain", payload);
                    return { content: [{ type: "text", text: result || "Native chain finished without a result." }] };
                }
            });

            pi.registerTool({
                name: "managed_parallel",
                description: "Run multiple Pi Manager native subagents concurrently and return an aggregate result.",
                parameters: ManagedParallelParams,
                promptSnippet: "managed_parallel(tasks, concurrency?, worktree?): run bounded native subagent tasks concurrently.",
                promptGuidelines: ["Use managed_parallel for independent advisory/research tasks. Use worktree isolation for writer tasks."],
                async execute(toolCallId, params, _signal, onUpdate, ctx) {
                    const rawTasks = Array.isArray((params as any).tasks) ? (params as any).tasks : [];
                    const payload = JSON.stringify({
                        bridge: "pi_manager_native_subagents",
                        kind: "managed_parallel",
                        toolCallId,
                        tasks: rawTasks.map((task: any) => ({ agent: String(task.agent ?? ""), task: String(task.task ?? "") })),
                        concurrency: (params as any).concurrency ? Number((params as any).concurrency) : undefined,
                        worktree: Boolean((params as any).worktree ?? false)
                    });
                    onUpdate?.({ content: [{ type: "text", text: `Starting ${rawTasks.length} native subagents…` }] });
                    const result = await ctx.ui.editor("PI_MANAGER_BRIDGE managed_parallel", payload);
                    return { content: [{ type: "text", text: result || "Native parallel run finished without a result." }] };
                }
            });
        }
        """

    private static let childExtensionSource = """
        import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
        import { StringEnum } from "@mariozechner/pi-ai";
        import { Type } from "typebox";

        const ContactSupervisorParams = Type.Object({
            kind: StringEnum(["progress_update", "need_decision", "interview_request"] as const, {
                description: "progress_update is non-blocking; need_decision and interview_request block for supervisor response."
            }),
            message: Type.String({ description: "Message/question for the supervisor." }),
            title: Type.Optional(Type.String({ description: "Short title for the supervisor request." }))
        }, { additionalProperties: false });

        export default function (pi: ExtensionAPI) {
            pi.registerTool({
                name: "contact_supervisor",
                description: "Contact the Pi Manager supervisor for progress updates or blocking decisions.",
                parameters: ContactSupervisorParams,
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
