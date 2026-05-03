import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { AutocompleteItem } from "@mariozechner/pi-tui";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const COMMAND_NAME = "subagents-toggle";
const PACKAGE_NAME = "npm:pi-subagents";
const ACTIONS = ["on", "off", "status"] as const;

type Action = (typeof ACTIONS)[number];
type Settings = {
	packages?: unknown;
	[key: string]: unknown;
};

type PackageEntry = string | { source?: unknown; [key: string]: unknown };

function parseAction(input: string): Action | undefined {
	const action = input.trim().toLowerCase();
	return ACTIONS.find((value) => value === action);
}

function getActionCompletions(prefix: string): AutocompleteItem[] | null {
	const normalizedPrefix = prefix.trim().toLowerCase();
	const matches = ACTIONS.filter((action) => action.startsWith(normalizedPrefix));
	return matches.length > 0 ? matches.map((action) => ({ value: action, label: action })) : null;
}

function readSettings(settingsPath: string): Settings {
	if (!existsSync(settingsPath)) {
		return {};
	}

	const raw = readFileSync(settingsPath, "utf8").trim();
	if (!raw) {
		return {};
	}

	const parsed = JSON.parse(raw) as unknown;
	if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
		throw new Error(`Expected ${settingsPath} to contain a JSON object.`);
	}

	return parsed as Settings;
}

function getSettingsPath(): string {
	return join(homedir(), ".pi", "agent", "settings.json");
}

function getPackages(settings: Settings, settingsPath: string): PackageEntry[] {
	const { packages } = settings;
	if (packages === undefined) {
		return [];
	}
	if (!Array.isArray(packages)) {
		throw new Error(`Expected settings.packages in ${settingsPath} to be an array.`);
	}
	return packages as PackageEntry[];
}

function isSubagentsEntry(entry: PackageEntry): boolean {
	if (typeof entry === "string") {
		return entry === PACKAGE_NAME;
	}

	return typeof entry?.source === "string" && entry.source === PACKAGE_NAME;
}

function isEnabled(packages: PackageEntry[]): boolean {
	return packages.some(isSubagentsEntry);
}

function writeSettings(settingsPath: string, settings: Settings): void {
	mkdirSync(dirname(settingsPath), { recursive: true });
	writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`, "utf8");
}

function announce(
	ctx: { hasUI: boolean; ui: { notify(message: string, level: "info" | "success" | "warning" | "error"): void } },
	message: string,
	level: "info" | "success" | "warning" | "error",
): void {
	if (ctx.hasUI) {
		ctx.ui.notify(message, level);
		return;
	}

	if (level === "error") {
		console.error(message);
		return;
	}

	console.log(message);
}

export default function subagentsToggleExtension(pi: ExtensionAPI) {
	pi.registerCommand(COMMAND_NAME, {
		description: "Enable, disable, or inspect the pi-subagents package",
		getArgumentCompletions: getActionCompletions,
		handler: async (args, ctx) => {
			const action = parseAction(args);
			if (!action) {
				announce(ctx, `Usage: /${COMMAND_NAME} on|off|status`, "warning");
				return;
			}

			const settingsPath = getSettingsPath();

			let settings: Settings;
			try {
				settings = readSettings(settingsPath);
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				announce(ctx, `Failed to read settings: ${message}`, "error");
				return;
			}

			let packages: PackageEntry[];
			try {
				packages = getPackages(settings, settingsPath);
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				announce(ctx, message, "error");
				return;
			}

			const enabled = isEnabled(packages);

			if (action === "status") {
				announce(ctx, `pi-subagents is ${enabled ? "enabled" : "disabled"}`, "info");
				return;
			}

			if (action === "on") {
				if (enabled) {
					announce(ctx, "pi-subagents is already enabled", "info");
					return;
				}

				settings.packages = [...packages, PACKAGE_NAME];
			}

			if (action === "off") {
				if (!enabled) {
					announce(ctx, "pi-subagents is already disabled", "info");
					return;
				}

				settings.packages = packages.filter((entry) => !isSubagentsEntry(entry));
			}

			try {
				writeSettings(settingsPath, settings);
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				announce(ctx, `Failed to write settings: ${message}`, "error");
				return;
			}

			announce(ctx, `${action === "on" ? "Enabled" : "Disabled"} pi-subagents. Reloading Pi...`, "success");
			await ctx.reload();
		},
	});
}
