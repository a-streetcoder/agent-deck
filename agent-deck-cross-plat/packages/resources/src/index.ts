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
export {
  writeAgentFile,
  writeSkillFile,
  deleteAgentFile,
  setAgentDisabledFile,
  deleteSkillDir,
  type WritableScope,
} from "./writer.ts";
export { scanEnv, writeEnvVar, type EnvEntry, type EnvScope } from "./env.ts";
export {
  detectProjectType,
  discoverProjects,
  discoverProjectsInRoot,
  type DiscoveryCandidate,
} from "./discovery.ts";
