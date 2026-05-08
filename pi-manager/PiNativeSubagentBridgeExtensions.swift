import Foundation

struct PiNativeSubagentBridgeExtensions {
    static func systemPromptAuditExtensionURL(fileManager: FileManager = .default) throws -> URL {
        try writeExtension(named: "system-prompt-audit-bridge.ts", content: systemPromptAuditExtensionSource, fileManager: fileManager)
    }

    static func askUserExtensionURL(fileManager: FileManager = .default) throws -> URL {
        try writeExtension(named: "pi-manager-ask-user-bridge.ts", content: askUserExtensionSource, fileManager: fileManager)
    }

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

    private static let askUserExtensionSource = """
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
        import { Type } from "typebox";

        type QuestionOption = { title: string; description?: string };
        type AskResponse =
            | { kind: "selection"; selections: string[]; comment?: string }
            | { kind: "freeform"; text: string };

        function normalizeOptions(raw: unknown): QuestionOption[] {
            if (!Array.isArray(raw)) return [];
            return raw.flatMap((item: unknown) => {
                if (typeof item === "string" && item.trim()) return [{ title: item.trim() }];
                if (item && typeof item === "object" && typeof (item as any).title === "string") {
                    const title = String((item as any).title).trim();
                    if (!title) return [];
                    const description = typeof (item as any).description === "string" ? String((item as any).description) : undefined;
                    return [{ title, description }];
                }
                return [];
            });
        }

        function parseBridgeResponse(raw: string | undefined): { response: AskResponse | null; cancelled: boolean; error?: string } {
            if (!raw || !raw.trim()) return { response: null, cancelled: true };
            try {
                const parsed = JSON.parse(raw);
                if (parsed?.cancelled) return { response: null, cancelled: true, error: parsed.error };
                if (parsed?.kind === "freeform") {
                    const text = String(parsed.text ?? "").trim();
                    return text ? { response: { kind: "freeform", text }, cancelled: false } : { response: null, cancelled: true };
                }
                if (parsed?.kind === "selection" && Array.isArray(parsed.selections)) {
                    const selections = parsed.selections.map((item: unknown) => String(item).trim()).filter(Boolean);
                    if (selections.length === 0) return { response: null, cancelled: true };
                    const comment = String(parsed.comment ?? "").trim();
                    return {
                        response: comment ? { kind: "selection", selections, comment } : { kind: "selection", selections },
                        cancelled: false
                    };
                }
                return { response: null, cancelled: true, error: "Pi Manager returned an invalid ask_user response." };
            } catch (error) {
                const message = error instanceof Error ? error.message : String(error);
                return { response: null, cancelled: true, error: message };
            }
        }

        function formatResponseSummary(response: AskResponse): string {
            if (response.kind === "freeform") return response.text;
            const selections = response.selections.join(", ");
            return response.comment ? `${selections} — ${response.comment}` : selections;
        }

        export default function (pi: ExtensionAPI) {
            pi.registerTool({
                name: "ask_user",
                label: "Ask User",
                description: "Ask the user one focused question with optional multiple-choice answers. Pi Manager renders this as a native macOS decision card.",
                promptSnippet: "Ask the user one focused question with optional multiple-choice answers to gather information interactively",
                promptGuidelines: [
                    "Before calling ask_user, gather context with tools and pass a short summary via the context field.",
                    "Use ask_user when the user's intent is ambiguous, when a decision requires explicit user input, or when multiple valid options exist.",
                    "Ask exactly one focused question per ask_user call.",
                    "Pi Manager always shows an inline optional comment field for choice questions."
                ],
                parameters: Type.Object({
                    question: Type.String({ description: "The question to ask the user." }),
                    context: Type.Optional(Type.String({ description: "Relevant context summary shown before the question." })),
                    options: Type.Optional(Type.Array(Type.Union([
                        Type.String({ description: "Short title for this option." }),
                        Type.Object({
                            title: Type.String({ description: "Short title for this option." }),
                            description: Type.Optional(Type.String({ description: "Longer description explaining this option." }))
                        })
                    ]), { description: "List of options for the user to choose from." })),
                    allowMultiple: Type.Optional(Type.Boolean({ description: "Allow selecting multiple options. Default: false." })),
                    allowFreeform: Type.Optional(Type.Boolean({ description: "Allow a custom freeform answer for choice prompts. Default: true." })),
                    allowComment: Type.Optional(Type.Boolean({ description: "Compatibility field. Pi Manager always shows an inline optional comment field for choice prompts." })),
                    timeout: Type.Optional(Type.Number({ description: "Reserved for compatibility. Pi Manager native prompts do not auto-dismiss yet." }))
                }, { additionalProperties: false }),
                async execute(toolCallId, params, signal, onUpdate, ctx) {
                    const question = String((params as any).question ?? "").trim();
                    const context = typeof (params as any).context === "string" ? String((params as any).context).trim() : undefined;
                    const options = normalizeOptions((params as any).options);
                    const payload = JSON.stringify({
                        bridge: "pi_manager_ask_user",
                        kind: "ask_user",
                        toolCallId,
                        question,
                        context: context || undefined,
                        options,
                        allowMultiple: Boolean((params as any).allowMultiple ?? false),
                        allowFreeform: Boolean((params as any).allowFreeform ?? true),
                        allowComment: options.length > 0,
                        timeout: typeof (params as any).timeout === "number" ? Number((params as any).timeout) : undefined
                    });

                    if (signal?.aborted) {
                        return {
                            content: [{ type: "text", text: "User cancelled the question" }],
                            details: { question, context, options, response: null, cancelled: true }
                        };
                    }

                    onUpdate?.({
                        content: [{ type: "text", text: "Waiting for user input..." }],
                        details: { question, context, options, response: null, cancelled: false }
                    });
                    const raw = await ctx.ui.editor("PI_MANAGER_BRIDGE ask_user", payload);
                    const result = parseBridgeResponse(raw);
                    if (result.cancelled || !result.response) {
                        return {
                            content: [{ type: "text", text: result.error ? `User cancelled the question (${result.error})` : "User cancelled the question" }],
                            details: { question, context, options, response: null, cancelled: true }
                        };
                    }

                    pi.events.emit("ask:answered", { question, context, response: result.response });
                    return {
                        content: [{ type: "text", text: `User answered: ${formatResponseSummary(result.response)}` }],
                        details: { question, context, options, response: result.response, cancelled: false }
                    };
                }
            });
        }
        """

    private static let parentExtensionSource = """
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
        import { StringEnum } from "@earendil-works/pi-ai";
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

        const AnswerSupervisorParams = Type.Object({
            requestID: Type.String({ description: "Pending supervisor request id from list_supervisor_requests." }),
            response: Type.String({ description: "Decision or answer to send to the blocked child." })
        }, { additionalProperties: false });

        const PlanStatus = StringEnum(["todo", "in_progress", "done", "blocked", "skipped"] as const, { description: "Plan item status." });
        const SessionPlanItem = Type.Object({
            id: Type.Optional(Type.String({ description: "Stable short id, e.g. inspect-ui or validate-build." })),
            title: Type.String({ description: "Short human-readable plan item." }),
            status: Type.Optional(PlanStatus)
        }, { additionalProperties: false });
        const SetSessionPlanParams = Type.Object({
            items: Type.Array(SessionPlanItem, { minItems: 0, maxItems: 12, description: "Short plan items for the current task. Empty clears the plan." })
        }, { additionalProperties: false });
        const SessionPlanUpdate = Type.Object({
            id: Type.String({ description: "Existing plan item id." }),
            title: Type.Optional(Type.String({ description: "Optional revised title." })),
            status: Type.Optional(PlanStatus)
        }, { additionalProperties: false });
        const UpdateSessionPlanParams = Type.Object({
            updates: Type.Array(SessionPlanUpdate, { minItems: 1, maxItems: 12, description: "Meaningful status/title transitions for existing plan items." })
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

            pi.registerTool({
                name: "list_supervisor_requests",
                description: "List pending Pi Manager native child supervisor requests for this parent session.",
                parameters: Type.Object({}, { additionalProperties: false }),
                promptSnippet: "list_supervisor_requests(): list pending native child questions awaiting a supervisor response.",
                promptGuidelines: ["Use list_supervisor_requests before answer_supervisor_request when a child needs a decision."],
                async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
                    const result = await ctx.ui.editor("PI_MANAGER_BRIDGE list_supervisor_requests", JSON.stringify({ kind: "list_supervisor_requests" }));
                    return { content: [{ type: "text", text: result || "[]" }] };
                }
            });

            pi.registerTool({
                name: "set_session_plan",
                description: "Set or replace the short Pi Manager current plan for this parent session.",
                parameters: SetSessionPlanParams,
                promptSnippet: "set_session_plan(items): show a short current-plan checklist in Pi Manager.",
                promptGuidelines: [
                    "Use set_session_plan for multi-step implementation/debugging work, not trivial one-shot answers.",
                    "Keep plans short: 3-8 items when possible; use stable ids and update only on meaningful transitions."
                ],
                async execute(toolCallId, params, _signal, _onUpdate, ctx) {
                    const rawItems = Array.isArray((params as any).items) ? (params as any).items : [];
                    const payload = JSON.stringify({
                        kind: "set_session_plan",
                        toolCallId,
                        items: rawItems.map((item: any) => ({
                            id: item.id ? String(item.id) : undefined,
                            title: String(item.title ?? ""),
                            status: item.status ? String(item.status) : undefined
                        }))
                    });
                    const result = await ctx.ui.editor("PI_MANAGER_BRIDGE set_session_plan", payload);
                    return { content: [{ type: "text", text: result || "Session plan updated." }] };
                }
            });

            pi.registerTool({
                name: "update_session_plan",
                description: "Update statuses/titles for existing Pi Manager current-plan items.",
                parameters: UpdateSessionPlanParams,
                promptSnippet: "update_session_plan(updates): update current-plan checklist statuses in Pi Manager.",
                promptGuidelines: ["Update only when a step starts, completes, blocks, skips, or materially changes."],
                async execute(toolCallId, params, _signal, _onUpdate, ctx) {
                    const rawUpdates = Array.isArray((params as any).updates) ? (params as any).updates : [];
                    const payload = JSON.stringify({
                        kind: "update_session_plan",
                        toolCallId,
                        updates: rawUpdates.map((item: any) => ({
                            id: String(item.id ?? ""),
                            title: item.title ? String(item.title) : undefined,
                            status: item.status ? String(item.status) : undefined
                        }))
                    });
                    const result = await ctx.ui.editor("PI_MANAGER_BRIDGE update_session_plan", payload);
                    return { content: [{ type: "text", text: result || "Session plan updated." }] };
                }
            });

            pi.registerTool({
                name: "answer_supervisor_request",
                description: "Answer a pending Pi Manager native child supervisor request.",
                parameters: AnswerSupervisorParams,
                promptSnippet: "answer_supervisor_request(requestID, response): answer a blocked native child subagent.",
                promptGuidelines: ["Use answer_supervisor_request only for pending request ids returned by list_supervisor_requests."],
                async execute(toolCallId, params, _signal, _onUpdate, ctx) {
                    const payload = JSON.stringify({
                        kind: "answer_supervisor_request",
                        toolCallId,
                        requestID: String((params as any).requestID ?? ""),
                        response: String((params as any).response ?? "")
                    });
                    const result = await ctx.ui.editor("PI_MANAGER_BRIDGE answer_supervisor_request", payload);
                    return { content: [{ type: "text", text: result || "Supervisor response routed." }] };
                }
            });
        }
        """

    private static let systemPromptAuditExtensionSource = """
        import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

        export default function (pi: ExtensionAPI) {
            pi.on("before_agent_start", async (event, ctx) => {
                const payload = JSON.stringify({
                    bridge: "pi_manager_system_prompt_audit",
                    kind: "system_prompt_audit",
                    scope: process.env.PI_MANAGER_NATIVE_SUBAGENT === "1" ? "child" : "parent",
                    parentSessionID: process.env.PI_MANAGER_PARENT_SESSION_ID,
                    runID: process.env.PI_MANAGER_SUBAGENT_RUN_ID,
                    agent: process.env.PI_MANAGER_SUBAGENT_AGENT,
                    systemPrompt: event.systemPrompt ?? ctx.getSystemPrompt()
                });
                await ctx.ui.editor("PI_MANAGER_BRIDGE system_prompt_audit", payload);
            });
        }
        """

    private static let childExtensionSource = """
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
        import { StringEnum } from "@earendil-works/pi-ai";
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
