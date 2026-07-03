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
