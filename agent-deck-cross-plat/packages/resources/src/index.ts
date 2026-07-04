export {
  agentCatalogDirs,
  BUILTIN_AGENTS_DIR,
  defaultRoots,
  piAgentHome,
  projectWatchDirs,
  skillCatalogDirs,
  watchDirs,
  type AgentCatalogDir,
  type ResourceRoots,
  type SkillCatalogDir,
} from "./paths.ts";
export { parseAgentFile, scanAgents, scanSkills } from "./scanner.ts";
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
export { writeAgentFile, writeSkillFile, type WritableScope } from "./writer.ts";
export { scanEnv, type EnvEntry } from "./env.ts";
