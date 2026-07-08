import type { ComponentType } from "react";
import {
  FileText,
  FolderTree,
  Globe,
  ListChecks,
  Pencil,
  Search,
  Terminal,
  Users,
  Wrench,
} from "lucide-react";
import type { ToolGroupVariant } from "./ToolGroupCard";

/**
 * Per-tool presentation (native PiAgentTranscriptNativeToolGroup toolVerb /
 * toolIcon): a friendly display name + a distinct icon for each known pi tool,
 * so a bash/read/edit call reads as "Shell" / "Read" / "Edit" with its own glyph
 * instead of the raw tool name under one generic terminal icon.
 */
export interface ToolPresentation {
  name: string;
  Icon: ComponentType<{ className?: string }>;
  variant: ToolGroupVariant;
}

interface ToolMeta {
  name: string;
  Icon: ComponentType<{ className?: string }>;
  variant?: ToolGroupVariant;
}

const TOOL_META: Record<string, ToolMeta> = {
  bash: { name: "Shell", Icon: Terminal },
  read: { name: "Read", Icon: FileText },
  edit: { name: "Edit", Icon: Pencil, variant: "diff" },
  write: { name: "Write", Icon: Pencil, variant: "diff" },
  grep: { name: "Search", Icon: Search },
  glob: { name: "Find files", Icon: Search },
  ls: { name: "List", Icon: FolderTree },
  web_search: { name: "Search web", Icon: Globe, variant: "web" },
  web_fetch: { name: "Fetch URL", Icon: Globe, variant: "web" },
  fetch_content: { name: "Fetch content", Icon: Globe, variant: "web" },
  get_search_content: { name: "Read web content", Icon: Globe, variant: "web" },
  set_session_plan: { name: "Plan", Icon: ListChecks },
  update_session_plan: { name: "Plan", Icon: ListChecks },
  managed_subagent: { name: "Agent", Icon: Users },
  subagent: { name: "Agent", Icon: Users },
};

/** Resolve a tool's card presentation; unknown tools keep their raw name + a wrench. */
export function toolPresentation(toolName: string): ToolPresentation {
  const meta = TOOL_META[toolName.toLowerCase()];
  if (meta) return { name: meta.name, Icon: meta.Icon, variant: meta.variant ?? "generic" };
  // MCP tools are namespaced `mcp__<server>__<tool>` — surface the tool part.
  if (toolName.startsWith("mcp__")) {
    const leaf = toolName.split("__").pop() || toolName;
    return { name: leaf, Icon: Wrench, variant: "mcp" };
  }
  return { name: toolName, Icon: Wrench, variant: "generic" };
}

/** The file path an edit/write/read tool acted on, if the args carry one. The
 *  args may be a parsed object OR the raw JSON-string pi forwards. */
export function toolFilePath(args: unknown): string | undefined {
  let obj: unknown = args;
  if (typeof args === "string") {
    try {
      obj = JSON.parse(args);
    } catch {
      return undefined;
    }
  }
  if (obj && typeof obj === "object" && !Array.isArray(obj)) {
    const record = obj as Record<string, unknown>;
    const value = record.file_path ?? record.path;
    if (typeof value === "string" && value.trim()) return value;
  }
  return undefined;
}
