export {
  agentCatalogDirs,
  appendSystemPromptPath,
  BUILTIN_AGENTS_DIR,
  defaultRoots,
  extensionCatalogDirs,
  piAgentHome,
  projectWatchDirs,
  promptCatalogDirs,
  skillCatalogDirs,
  watchDirs,
  type AgentCatalogDir,
  type ExtensionCatalogDir,
  type PromptCatalogDir,
  type ResourceRoots,
  type SkillCatalogDir,
} from "./paths.ts";
export {
  deleteMcpServer,
  isValidHttpMcpUrl,
  isValidMcpServerName,
  mcpConfigPath,
  McpConfigError,
  readMcpServers,
  writeMcpServer,
  type McpConfigScope,
  type McpServerEntry,
  type McpServerInput,
  type McpTransport,
} from "./mcp.ts";
export {
  parseAgentFile,
  scanAgents,
  scanExtensions,
  scanPrompts,
  scanSkills,
  type DiscoveredExtension,
} from "./scanner.ts";
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
  renamePromptFile,
  renameAgentFile,
  renameSkillDir,
  importSkillFile,
  importSkillsFromClone,
  type SkillImportResult,
  type WritableScope,
} from "./writer.ts";
export { scanEnv, writeEnvVar, type EnvEntry, type EnvScope } from "./env.ts";
export { resolveSkillSource, type RemoteSkillSource } from "./skillSource.ts";
export {
  detectProjectType,
  discoverProjects,
  discoverProjectsInRoot,
  type DiscoveryCandidate,
} from "./discovery.ts";
export { listProjectFiles } from "./files.ts";
export {
  listProviders,
  isKnownProvider,
  logoutProvider,
  type ProviderAuthInfo,
} from "./providers.ts";
export {
  ProviderLoginManager,
  type LoginEvent,
  type LoginStatus,
  type ProviderLoginFn,
  type ProviderLoginCallbacks,
} from "./providerLogin.ts";
export {
  loopsDir,
  loopSlug,
  parseLoopFile,
  scanLoops,
  writeLoopFile,
  deleteLoopFile,
  duplicateLoop,
  type LoopEdit,
} from "./loops.ts";
