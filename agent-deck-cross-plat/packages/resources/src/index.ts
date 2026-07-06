export {
  agentCatalogDirs,
  appendSystemPromptPath,
  BUILTIN_AGENTS_DIR,
  defaultRoots,
  piAgentHome,
  projectWatchDirs,
  promptCatalogDirs,
  skillCatalogDirs,
  watchDirs,
  type AgentCatalogDir,
  type PromptCatalogDir,
  type ResourceRoots,
  type SkillCatalogDir,
} from "./paths.ts";
export {
  mcpConfigPath,
  readMcpServers,
  type McpConfigScope,
  type McpServerEntry,
  type McpTransport,
} from "./mcp.ts";
export { parseAgentFile, scanAgents, scanPrompts, scanSkills } from "./scanner.ts";
export { ensureDirs, watchResources } from "./watcher.ts";
export {
  applyAgentOverride,
  computeBuiltinOverride,
  EDITABLE_OVERRIDE_KEYS,
  mergeWithUnmanagedOverrideFields,
  readAgentOverrides,
  writeBuiltinAgentOverride,
  type AgentEdit,
  type AgentOverride,
} from "./overrides.ts";
export {
  writeAgentFile,
  writeSkillFile,
  writePromptFile,
  deleteAgentFile,
  setAgentDisabledFile,
  deleteSkillDir,
  deletePromptFile,
  type WritableScope,
} from "./writer.ts";
export { scanEnv, writeEnvVar, type EnvEntry, type EnvScope } from "./env.ts";
export {
  detectProjectType,
  discoverProjects,
  discoverProjectsInRoot,
  type DiscoveryCandidate,
} from "./discovery.ts";
export { listProjectFiles } from "./files.ts";
