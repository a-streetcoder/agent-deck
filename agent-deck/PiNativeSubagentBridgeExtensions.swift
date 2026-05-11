import Foundation

struct PiNativeSubagentBridgeExtensions {
    static func systemPromptAuditExtensionURL(fileManager: FileManager = .default) throws -> URL {
        try writeExtension(named: "system-prompt-audit-bridge.ts", content: systemPromptAuditExtensionSource, fileManager: fileManager)
    }

    static func askUserExtensionURL(fileManager: FileManager = .default) throws -> URL {
        try writeExtension(named: "agent-deck-ask-user-bridge.ts", content: askUserExtensionSource, fileManager: fileManager)
    }

    static func parentExtensionURL(fileManager: FileManager = .default) throws -> URL {
        try writeExtension(named: "managed-subagent-bridge.ts", content: parentExtensionSource, fileManager: fileManager)
    }

    static func childExtensionURL(fileManager: FileManager = .default) throws -> URL {
        try writeExtension(named: "contact-supervisor-bridge.ts", content: childExtensionSource, fileManager: fileManager)
    }

    static func webAccessExtensionURL(fileManager: FileManager = .default) throws -> URL {
        try writeExtension(named: "agent-deck-web-access.ts", content: webAccessExtensionSource, fileManager: fileManager)
    }

    static func writeExtension(named fileName: String, content: String, fileManager: FileManager) throws -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = appSupport
            .appendingPathComponent("\(AppBrand.displayName)", isDirectory: true)
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
                return { response: null, cancelled: true, error: "\(AppBrand.displayName) returned an invalid ask_user response." };
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
                description: "Ask the user one focused question with optional multiple-choice answers. \(AppBrand.displayName) renders this as a native macOS decision card.",
                promptSnippet: "Ask the user one focused question with optional multiple-choice answers to gather information interactively",
                promptGuidelines: [
                    "Before calling ask_user, gather context with tools and pass a short summary via the context field.",
                    "Use ask_user when the user's intent is ambiguous, when a decision requires explicit user input, or when multiple valid options exist.",
                    "Ask exactly one focused question per ask_user call.",
                    "\(AppBrand.displayName) always shows an inline optional comment field for choice questions."
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
                    allowComment: Type.Optional(Type.Boolean({ description: "Compatibility field. \(AppBrand.displayName) always shows an inline optional comment field for choice prompts." })),
                    timeout: Type.Optional(Type.Number({ description: "Reserved for compatibility. \(AppBrand.displayName) native prompts do not auto-dismiss yet." }))
                }, { additionalProperties: false }),
                async execute(toolCallId, params, signal, onUpdate, ctx) {
                    const question = String((params as any).question ?? "").trim();
                    const context = typeof (params as any).context === "string" ? String((params as any).context).trim() : undefined;
                    const options = normalizeOptions((params as any).options);
                    const payload = JSON.stringify({
                        bridge: "agent_deck_ask_user",
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
                    const raw = await ctx.ui.editor("AGENT_DECK_BRIDGE ask_user", payload);
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
                description: "Delegate a bounded task to a \(AppBrand.displayName) native subagent. Use this when a specialized subagent can work separately and return a compact result.",
                parameters: ManagedSubagentParams,
                promptSnippet: "managed_subagent(agent, task, context?): delegate to a \(AppBrand.displayName) native subagent and get a compact result.",
                promptGuidelines: [
                    "Use managed_subagent for separable specialist work; keep tasks narrow and include expected output.",
                    "Do not call managed_subagent just to continue normal conversation."
                ],
                async execute(toolCallId, params, _signal, onUpdate, ctx) {
                    const payload = JSON.stringify({
                        bridge: "agent_deck_native_subagents",
                        kind: "managed_subagent",
                        toolCallId,
                        agent: String((params as any).agent ?? ""),
                        task: String((params as any).task ?? ""),
                        context: (params as any).context ? String((params as any).context) : undefined,
                        reads: Array.isArray((params as any).reads) ? (params as any).reads.map((item: any) => String(item)) : undefined
                    });
                    onUpdate?.({ content: [{ type: "text", text: `Starting native subagent ${(params as any).agent}…` }] });
                    const result = await ctx.ui.editor("AGENT_DECK_BRIDGE managed_subagent", payload);
                    return { content: [{ type: "text", text: result || "Native subagent finished without a result." }] };
                }
            });

            pi.registerTool({
                name: "managed_parallel",
                description: "Run multiple \(AppBrand.displayName) native subagents concurrently and return an aggregate result.",
                parameters: ManagedParallelParams,
                promptSnippet: "managed_parallel(tasks, concurrency?, worktree?): run bounded native subagent tasks concurrently.",
                promptGuidelines: ["Use managed_parallel for independent advisory/research tasks. Use worktree isolation for writer tasks."],
                async execute(toolCallId, params, _signal, onUpdate, ctx) {
                    const rawTasks = Array.isArray((params as any).tasks) ? (params as any).tasks : [];
                    const payload = JSON.stringify({
                        bridge: "agent_deck_native_subagents",
                        kind: "managed_parallel",
                        toolCallId,
                        tasks: rawTasks.map((task: any) => ({ agent: String(task.agent ?? ""), task: String(task.task ?? "") })),
                        concurrency: (params as any).concurrency ? Number((params as any).concurrency) : undefined,
                        worktree: Boolean((params as any).worktree ?? false)
                    });
                    onUpdate?.({ content: [{ type: "text", text: `Starting ${rawTasks.length} native subagents…` }] });
                    const result = await ctx.ui.editor("AGENT_DECK_BRIDGE managed_parallel", payload);
                    return { content: [{ type: "text", text: result || "Native parallel run finished without a result." }] };
                }
            });

            pi.registerTool({
                name: "list_supervisor_requests",
                description: "List pending \(AppBrand.displayName) native child supervisor requests for this parent session.",
                parameters: Type.Object({}, { additionalProperties: false }),
                promptSnippet: "list_supervisor_requests(): list pending native child questions awaiting a supervisor response.",
                promptGuidelines: ["Use list_supervisor_requests before answer_supervisor_request when a child needs a decision."],
                async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
                    const result = await ctx.ui.editor("AGENT_DECK_BRIDGE list_supervisor_requests", JSON.stringify({ kind: "list_supervisor_requests" }));
                    return { content: [{ type: "text", text: result || "[]" }] };
                }
            });

            pi.registerTool({
                name: "set_session_plan",
                description: "Set or replace the short \(AppBrand.displayName) current plan for this parent session.",
                parameters: SetSessionPlanParams,
                promptSnippet: "set_session_plan(items): show a short current-plan checklist in \(AppBrand.displayName).",
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
                    const result = await ctx.ui.editor("AGENT_DECK_BRIDGE set_session_plan", payload);
                    return { content: [{ type: "text", text: result || "Session plan updated." }] };
                }
            });

            pi.registerTool({
                name: "update_session_plan",
                description: "Update statuses/titles for existing \(AppBrand.displayName) current-plan items.",
                parameters: UpdateSessionPlanParams,
                promptSnippet: "update_session_plan(updates): update current-plan checklist statuses in \(AppBrand.displayName).",
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
                    const result = await ctx.ui.editor("AGENT_DECK_BRIDGE update_session_plan", payload);
                    return { content: [{ type: "text", text: result || "Session plan updated." }] };
                }
            });

            pi.registerTool({
                name: "answer_supervisor_request",
                description: "Answer a pending \(AppBrand.displayName) native child supervisor request.",
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
                    const result = await ctx.ui.editor("AGENT_DECK_BRIDGE answer_supervisor_request", payload);
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
                    bridge: "agent_deck_system_prompt_audit",
                    kind: "system_prompt_audit",
                    scope: process.env.AGENT_DECK_NATIVE_SUBAGENT === "1" ? "child" : "parent",
                    parentSessionID: process.env.AGENT_DECK_PARENT_SESSION_ID,
                    runID: process.env.AGENT_DECK_SUBAGENT_RUN_ID,
                    agent: process.env.AGENT_DECK_SUBAGENT_AGENT,
                    systemPrompt: event.systemPrompt ?? ctx.getSystemPrompt()
                });
                await ctx.ui.editor("AGENT_DECK_BRIDGE system_prompt_audit", payload);
            });
        }
        """

    private static let webAccessExtensionSource = #"""
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
        import { Type } from "typebox";

        type SearchResult = {
            title: string;
            url: string;
            text?: string;
            publishedDate?: string;
            author?: string;
        };

        type StoredEntry = {
            query?: string;
            title: string;
            url: string;
            text: string;
            publishedDate?: string;
            author?: string;
        };

        type StoredResult = {
            type: "search" | "fetch";
            id: string;
            queries?: string[];
            entries: StoredEntry[];
            createdAt: string;
        };

        const store = new Map<string, StoredResult>();
        const MAX_STORED_RESULTS = 50;
        const MAX_RETURN_CHARS = 50000;

        function apiKey(): string | null {
            const key = process.env.EXA_API_KEY?.trim();
            return key && key.length > 0 ? key : null;
        }

        function makeID(prefix: string): string {
            return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
        }

        function remember(result: StoredResult): void {
            store.set(result.id, result);
            while (store.size > MAX_STORED_RESULTS) {
                const first = store.keys().next().value;
                if (!first) break;
                store.delete(first);
            }
        }

        async function exa(path: "search" | "contents", body: Record<string, unknown>, signal?: AbortSignal): Promise<any> {
            const key = apiKey();
            if (!key) throw new Error("Missing EXA_API_KEY. Add it in Agent Deck Environment settings or your .pi/.env file.");
            const response = await fetch(`https://api.exa.ai/${path}`, {
                method: "POST",
                headers: {
                    "Content-Type": "application/json",
                    "x-api-key": key
                },
                body: JSON.stringify(body),
                signal
            });
            const text = await response.text();
            let json: any = null;
            try {
                json = text ? JSON.parse(text) : null;
            } catch {
                json = null;
            }
            if (!response.ok) {
                const message = json?.error || json?.message || text || `HTTP ${response.status}`;
                throw new Error(String(message));
            }
            return json;
        }

        function asString(value: unknown): string | undefined {
            return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
        }

        function cleanText(value: unknown): string {
            if (typeof value === "string") return value.trim();
            if (value && typeof value === "object") {
                const anyValue = value as any;
                return String(anyValue.text ?? anyValue.content ?? "").trim();
            }
            return "";
        }

        function truncate(text: string, maxChars = MAX_RETURN_CHARS): string {
            if (text.length <= maxChars) return text;
            return `${text.slice(0, maxChars).trimEnd()}\n\n[Truncated by Agent Deck web access to ${maxChars} characters.]`;
        }

        function normalizeQueries(params: any): string[] {
            const raw = Array.isArray(params?.queries) ? params.queries : (params?.query !== undefined ? [params.query] : []);
            return raw.map((item: unknown) => String(item ?? "").trim()).filter(Boolean).slice(0, 4);
        }

        function normalizeURLs(params: any): string[] {
            const raw = Array.isArray(params?.urls) ? params.urls : (params?.url !== undefined ? [params.url] : []);
            return raw.map((item: unknown) => String(item ?? "").trim()).filter(Boolean).slice(0, 12);
        }

        function domainFilters(params: any): { includeDomains?: string[]; excludeDomains?: string[] } {
            const filters = Array.isArray(params?.domainFilter) ? params.domainFilter : [];
            const includeDomains: string[] = [];
            const excludeDomains: string[] = [];
            for (const item of filters) {
                const raw = String(item ?? "").trim();
                if (!raw) continue;
                if (raw.startsWith("-")) {
                    const domain = raw.slice(1).trim();
                    if (domain) excludeDomains.push(domain);
                } else {
                    includeDomains.push(raw);
                }
            }
            return {
                ...(includeDomains.length ? { includeDomains } : {}),
                ...(excludeDomains.length ? { excludeDomains } : {})
            };
        }

        function recencyStart(value: unknown): string | undefined {
            const recency = String(value ?? "").trim().toLowerCase();
            const days = recency === "day" ? 1 : recency === "week" ? 7 : recency === "month" ? 31 : recency === "year" ? 366 : 0;
            if (!days) return undefined;
            const date = new Date(Date.now() - days * 24 * 60 * 60 * 1000);
            return date.toISOString();
        }

        function entryFromResult(result: any, query?: string): StoredEntry | null {
            const url = asString(result?.url);
            if (!url) return null;
            const title = asString(result?.title) ?? url;
            const text = cleanText(result?.text) || cleanText(result?.highlights?.join?.("\n\n")) || "";
            return {
                query,
                title,
                url,
                text,
                publishedDate: asString(result?.publishedDate),
                author: asString(result?.author)
            };
        }

        function markdownForEntry(entry: StoredEntry): string {
            const lines = [
                "---",
                `title: ${entry.title}`,
                `source: ${entry.url}`,
                entry.query ? `query: ${entry.query}` : undefined,
                entry.publishedDate ? `publishedDate: ${entry.publishedDate}` : undefined,
                entry.author ? `author: ${entry.author}` : undefined,
                "---",
                "",
                entry.text || `No extracted text was returned for ${entry.url}.`
            ].filter((line): line is string => line !== undefined);
            return lines.join("\n");
        }

        function searchSummary(responseId: string, queries: string[], entries: StoredEntry[]): string {
            const lines: string[] = [];
            lines.push(`Search stored as ${responseId}.`);
            for (const query of queries) {
                lines.push("");
                lines.push(`## ${query}`);
                const matches = entries.filter((entry) => entry.query === query);
                if (matches.length === 0) {
                    lines.push("No results.");
                    continue;
                }
                matches.forEach((entry, index) => {
                    lines.push(`${index + 1}. [${entry.title}](${entry.url})`);
                    const preview = entry.text.replace(/\s+/g, " ").slice(0, 240).trim();
                    if (preview) lines.push(`   ${preview}${entry.text.length > 240 ? "..." : ""}`);
                });
            }
            lines.push("");
            lines.push(`Use get_search_content({ responseId: "${responseId}", urlIndex: 0 }) to retrieve full stored content.`);
            return lines.join("\n");
        }

        function selectEntry(data: StoredResult, params: any): StoredEntry | null {
            if (typeof params?.urlIndex === "number") return data.entries[Math.trunc(params.urlIndex)] ?? null;
            if (typeof params?.queryIndex === "number") {
                const query = data.queries?.[Math.trunc(params.queryIndex)];
                return data.entries.find((entry) => entry.query === query) ?? null;
            }
            const url = asString(params?.url);
            if (url) return data.entries.find((entry) => entry.url === url) ?? null;
            const query = asString(params?.query);
            if (query) return data.entries.find((entry) => entry.query === query) ?? null;
            return data.entries[0] ?? null;
        }

        export default function (pi: ExtensionAPI) {
            pi.registerTool({
                name: "web_search",
                label: "Web Search",
                description: "Search the web with Exa and store returned page content for later retrieval.",
                promptSnippet: "Use web_search for current web research. Use get_search_content with the returned responseId when full content is needed.",
                parameters: Type.Object({
                    query: Type.Optional(Type.String({ description: "Single search query." })),
                    queries: Type.Optional(Type.Array(Type.String(), { description: "Up to 4 search queries." })),
                    numResults: Type.Optional(Type.Number({ description: "Results per query. Default 5, max 10." })),
                    includeContent: Type.Optional(Type.Boolean({ description: "Compatibility flag. Agent Deck always stores returned Exa text when available." })),
                    recencyFilter: Type.Optional(Type.String({ description: "Optional recency filter: day, week, month, or year." })),
                    domainFilter: Type.Optional(Type.Array(Type.String(), { description: "Domains to include, or prefix with '-' to exclude." }))
                }, { additionalProperties: false }),
                async execute(_toolCallId, params, signal) {
                    const queries = normalizeQueries(params);
                    if (queries.length === 0) {
                        return { content: [{ type: "text", text: "Error: No query provided. Use query or queries." }], details: { error: "No query provided" } };
                    }
                    try {
                        const numResults = Math.max(1, Math.min(10, Number((params as any).numResults ?? 5)));
                        const startPublishedDate = recencyStart((params as any).recencyFilter);
                        const entries: StoredEntry[] = [];
                        const curatedQueries: any[] = [];

                        for (const query of queries) {
                            const body: Record<string, unknown> = {
                                query,
                                numResults,
                                contents: { text: true },
                                ...domainFilters(params)
                            };
                            if (startPublishedDate) body.startPublishedDate = startPublishedDate;
                            const json = await exa("search", body, signal);
                            const results = Array.isArray(json?.results) ? json.results : [];
                            const queryEntries = results.flatMap((result: any) => {
                                const entry = entryFromResult(result, query);
                                return entry ? [entry] : [];
                            });
                            entries.push(...queryEntries);
                            curatedQueries.push({
                                query,
                                sources: queryEntries.map((entry) => ({
                                    title: entry.title,
                                    url: entry.url,
                                    publishedDate: entry.publishedDate,
                                    author: entry.author
                                }))
                            });
                        }

                        const responseId = makeID("search");
                        remember({ type: "search", id: responseId, queries, entries, createdAt: new Date().toISOString() });
                        return {
                            content: [{ type: "text", text: searchSummary(responseId, queries, entries) }],
                            details: {
                                responseId,
                                queries,
                                queryCount: queries.length,
                                successfulQueries: queries.length,
                                totalResults: entries.length,
                                urls: entries.map((entry) => entry.url),
                                curatedQueries
                            }
                        };
                    } catch (error) {
                        const message = error instanceof Error ? error.message : String(error);
                        return { content: [{ type: "text", text: `Error: ${message}` }], details: { error: message, queries } };
                    }
                }
            });

            pi.registerTool({
                name: "fetch_content",
                label: "Fetch Content",
                description: "Fetch URL content with Exa and store it for later retrieval.",
                promptSnippet: "Use fetch_content for specific URLs; use get_search_content with the returned responseId for full stored content.",
                parameters: Type.Object({
                    url: Type.Optional(Type.String({ description: "Single URL to fetch." })),
                    urls: Type.Optional(Type.Array(Type.String(), { description: "Multiple URLs to fetch." }))
                }, { additionalProperties: false }),
                async execute(_toolCallId, params, signal) {
                    const urls = normalizeURLs(params);
                    if (urls.length === 0) {
                        return { content: [{ type: "text", text: "Error: No URL provided. Use url or urls." }], details: { error: "No URL provided" } };
                    }
                    try {
                        const json = await exa("contents", { urls, text: true }, signal);
                        const results = Array.isArray(json?.results) ? json.results : [];
                        const entries = results.flatMap((result: any) => {
                            const entry = entryFromResult(result);
                            return entry ? [entry] : [];
                        });
                        const responseId = makeID("fetch");
                        remember({ type: "fetch", id: responseId, entries, createdAt: new Date().toISOString() });

                        const lines = entries.length === 1
                            ? [markdownForEntry(entries[0]), "", `Use get_search_content({ responseId: "${responseId}", urlIndex: 0 }) for stored content.`]
                            : [
                                `Fetched ${entries.length}/${urls.length} URLs. Stored as ${responseId}.`,
                                "",
                                ...entries.map((entry) => `- ${entry.title} (${entry.text.length} chars)`),
                                "",
                                `Use get_search_content({ responseId: "${responseId}", urlIndex: 0 }) to retrieve full content.`
                            ];

                        return {
                            content: [{ type: "text", text: truncate(lines.join("\n")) }],
                            details: {
                                responseId,
                                urls,
                                urlCount: urls.length,
                                successful: entries.length,
                                title: entries[0]?.title,
                                url: entries[0]?.url,
                                totalChars: entries.reduce((sum, entry) => sum + entry.text.length, 0)
                            }
                        };
                    } catch (error) {
                        const message = error instanceof Error ? error.message : String(error);
                        return { content: [{ type: "text", text: `Error: ${message}` }], details: { error: message, urls, urlCount: urls.length, successful: 0 } };
                    }
                }
            });

            pi.registerTool({
                name: "get_search_content",
                label: "Read Web Content",
                description: "Retrieve full content from a previous web_search or fetch_content call.",
                promptSnippet: "Use after web_search or fetch_content when full stored content is needed.",
                parameters: Type.Object({
                    responseId: Type.String({ description: "The responseId returned by web_search or fetch_content." }),
                    query: Type.Optional(Type.String({ description: "Retrieve the first stored result for this query." })),
                    queryIndex: Type.Optional(Type.Number({ description: "Retrieve the first stored result for this query index." })),
                    url: Type.Optional(Type.String({ description: "Retrieve stored content for this URL." })),
                    urlIndex: Type.Optional(Type.Number({ description: "Retrieve stored content at this URL index." }))
                }, { additionalProperties: false }),
                async execute(_toolCallId, params) {
                    const responseId = String((params as any).responseId ?? "").trim();
                    const data = store.get(responseId);
                    if (!data) {
                        return { content: [{ type: "text", text: `Error: No stored web content for "${responseId}".` }], details: { error: "Not found", responseId } };
                    }
                    const entry = selectEntry(data, params);
                    if (!entry) {
                        return { content: [{ type: "text", text: `Error: No matching stored content for "${responseId}".` }], details: { error: "No matching content", responseId, resultCount: data.entries.length } };
                    }
                    return {
                        content: [{ type: "text", text: truncate(markdownForEntry(entry)) }],
                        details: {
                            responseId,
                            url: entry.url,
                            title: entry.title,
                            query: entry.query,
                            resultCount: data.entries.length,
                            totalChars: entry.text.length
                        }
                    };
                }
            });
        }
        """#

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
                description: "Contact the \(AppBrand.displayName) supervisor for progress updates or blocking decisions.",
                parameters: ContactSupervisorParams,
                promptSnippet: "contact_supervisor(kind, message, title?): update or ask the \(AppBrand.displayName) supervisor.",
                promptGuidelines: [
                    "Use progress_update sparingly for meaningful progress.",
                    "Use need_decision only when blocked on a user/product/scope decision.",
                    "Return routine final results normally instead of contacting the supervisor."
                ],
                async execute(toolCallId, params, _signal, _onUpdate, ctx) {
                    const kind = String((params as any).kind ?? "progress_update");
                    const payload = JSON.stringify({
                        bridge: "agent_deck_native_subagents",
                        kind: "contact_supervisor",
                        toolCallId,
                        requestKind: kind,
                        title: (params as any).title ? String((params as any).title) : undefined,
                        message: String((params as any).message ?? ""),
                        runID: process.env.AGENT_DECK_SUBAGENT_RUN_ID,
                        agent: process.env.AGENT_DECK_SUBAGENT_AGENT
                    });
                    const result = await ctx.ui.editor("AGENT_DECK_BRIDGE contact_supervisor", payload);
                    return { content: [{ type: "text", text: result || "Supervisor acknowledged." }] };
                }
            });
        }
        """
}
