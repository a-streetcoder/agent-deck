import { useEffect, useState } from "react";
import type { SkillInfo } from "@agent-deck/domain";
import { useAppStore } from "../state/store.ts";
import { ScopeChip } from "../components/ScopeChip.tsx";

export function SkillsScreen() {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const [skills, setSkills] = useState<SkillInfo[]>([]);

  useEffect(() => {
    const query = currentProjectId ? `?projectId=${encodeURIComponent(currentProjectId)}` : "";
    void fetch(`/resources/skills${query}`)
      .then((response) => response.json())
      .then((data: { skills: SkillInfo[] }) => setSkills(data.skills));
  }, [currentProjectId, resourcesVersion]);

  return (
    <div className="flex-1 overflow-y-auto px-6 py-4" data-testid="skills-screen">
      <div className="space-y-2">
        {skills.map((skill) => (
          <div
            key={skill.filePath}
            className="rounded-lg border border-border-subtle bg-surface-elevated px-4 py-3"
            data-testid="skill-row"
            data-skill-name={skill.name}
          >
            <div className="flex items-center gap-2">
              <span className="font-medium text-text-primary">{skill.name}</span>
              <ScopeChip scope={skill.scope} />
            </div>
            <div className="mt-1 text-sm text-text-secondary">{skill.description}</div>
          </div>
        ))}
        {skills.length === 0 ? (
          <div className="mt-8 text-center text-text-muted">
            No skills found in ~/.pi/agent/skills or this project's .pi/skills.
          </div>
        ) : null}
      </div>
    </div>
  );
}
