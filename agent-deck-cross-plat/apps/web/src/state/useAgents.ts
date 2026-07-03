import { useEffect, useState } from "react";
import type { AgentInfo } from "@agent-deck/domain";
import { useAppStore } from "./store.ts";

/** Agents for the current project, refetched on resources_changed pushes. */
export function useAgents(): AgentInfo[] {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const [agents, setAgents] = useState<AgentInfo[]>([]);

  useEffect(() => {
    const query = currentProjectId ? `?projectId=${encodeURIComponent(currentProjectId)}` : "";
    let cancelled = false;
    void fetch(`/resources/agents${query}`)
      .then((response) => response.json())
      .then((data: { agents: AgentInfo[] }) => {
        if (!cancelled) setAgents(data.agents);
      });
    return () => {
      cancelled = true;
    };
  }, [currentProjectId, resourcesVersion]);

  return agents;
}
