#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

import { discoverAgents, discoverAgentsAll, buildBuiltinOverrideConfig } from '/opt/homebrew/lib/node_modules/pi-subagents/agents.ts';
import { serializeAgent } from '/opt/homebrew/lib/node_modules/pi-subagents/agent-serializer.ts';
import { parseChain, serializeChain } from '/opt/homebrew/lib/node_modules/pi-subagents/chain-serializer.ts';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');
const fixturesRoot = path.join(__dirname, 'parity', 'fixtures');
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'pi-manager-parity-'));
const swiftHarness = path.join(tmpRoot, 'parity-harness');

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed\nSTDOUT:\n${result.stdout}\nSTDERR:\n${result.stderr}`);
  }
  return result.stdout;
}

function copyDir(src, dst) {
  fs.mkdirSync(dst, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const from = path.join(src, entry.name);
    const to = path.join(dst, entry.name);
    if (entry.isDirectory()) copyDir(from, to);
    else fs.copyFileSync(from, to);
  }
}

function normPath(value) {
  return value ? value.replace(/^\/private/, '') : value;
}

function packageConfigFromFixture(jsonPath) {
  const config = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
  if (config.unknownFields) {
    config.extraFields = config.unknownFields;
    delete config.unknownFields;
  }
  return config;
}

function normalizeAgent(config) {
  return {
    name: config.name,
    description: config.description,
    model: config.model ?? null,
    fallbackModels: config.fallbackModels ?? [],
    thinking: config.thinking ?? null,
    systemPromptMode: config.systemPromptMode,
    inheritProjectContext: config.inheritProjectContext,
    inheritSkills: config.inheritSkills,
    disabled: config.disabled ?? null,
    tools: config.tools ?? null,
    mcpDirectTools: config.mcpDirectTools ?? null,
    extensions: config.extensions ?? null,
    skills: config.skills ?? [],
    output: config.output ?? null,
    defaultReads: config.defaultReads ?? null,
    defaultProgress: config.defaultProgress ?? null,
    interactive: config.interactive ?? null,
    maxSubagentDepth: config.maxSubagentDepth ?? null,
    systemPrompt: config.systemPrompt,
    unknownFields: config.extraFields ?? {},
  };
}

function byName(items) {
  return [...items].sort((a, b) => (a.name || '').localeCompare(b.name || ''));
}

function normalizePackageSummary(projectRoot) {
  const all = discoverAgentsAll(projectRoot);
  const effective = discoverAgents(projectRoot, 'both').agents;
  const settingsPaths = [all.userSettingsPath, all.projectSettingsPath].filter(Boolean);
  return {
    builtin: byName(all.builtin.map((agent) => ({ name: agent.name, filePath: normPath(agent.filePath), source: 'Builtin', config: normalizeAgent(agent) }))),
    global: byName(all.user.map((agent) => ({ name: agent.name, filePath: normPath(agent.filePath), source: 'Global', config: normalizeAgent(agent) }))),
    project: byName(all.project.map((agent) => ({ name: agent.name, filePath: normPath(agent.filePath), source: 'Project', config: normalizeAgent(agent) }))),
    effective: byName(effective.map((agent) => ({
      name: agent.name,
      sourcePath: normPath(agent.filePath),
      resolutionKind: agent.source === 'builtin' ? (agent.override ? 'Builtin + Override' : 'builtin') : (agent.source === 'user' ? 'Global Replacement' : 'Project Replacement'),
      userOverridePath: agent.override?.scope === 'user' ? agent.override.path : null,
      projectOverridePath: agent.override?.scope === 'project' ? agent.override.path : null,
      resolved: normalizeAgent(agent),
    }))),
    chains: byName(all.chains.map((chain) => ({
      name: chain.name,
      filePath: normPath(chain.filePath),
      source: chain.source === 'project' ? 'Project' : 'Global',
      description: chain.description,
      extraFields: chain.extraFields ?? {},
      steps: chain.steps.map((step) => ({
        agent: step.agent,
        output: typeof step.output === 'string' ? step.output : null,
        outputDisabled: step.output === false,
        reads: Array.isArray(step.reads) ? step.reads : null,
        readsDisabled: step.reads === false,
        model: step.model ?? null,
        skills: Array.isArray(step.skills) ? step.skills : null,
        skillsDisabled: step.skills === false,
        progress: step.progress ?? null,
        body: step.task ?? '',
      })),
    }))),
    settings: settingsPaths.map((settingsPath) => {
      const json = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
      const subagents = json.subagents ?? {};
      return {
        path: normPath(settingsPath),
        disableBuiltins: subagents.disableBuiltins ?? null,
        packages: json.packages ?? [],
        agentOverrides: Object.entries(subagents.agentOverrides ?? {}).sort(([a], [b]) => a.localeCompare(b)).map(([agentName, values]) => ({
          agentName,
          settingsPath,
          values,
        })),
      };
    }),
  };
}

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === 'object') {
    return Object.keys(value).sort().reduce((acc, key) => {
      acc[key] = stable(value[key]);
      return acc;
    }, {});
  }
  return value;
}

function assertEqual(label, actual, expected) {
  const a = JSON.stringify(stable(actual), null, 2);
  const e = JSON.stringify(stable(expected), null, 2);
  if (a !== e) {
    const outDir = path.join(tmpRoot, 'failures');
    fs.mkdirSync(outDir, { recursive: true });
    fs.writeFileSync(path.join(outDir, `${label}.actual.json`), a + '\n');
    fs.writeFileSync(path.join(outDir, `${label}.expected.json`), e + '\n');
    throw new Error(`${label} mismatch. See ${outDir}`);
  }
  console.log(`✓ ${label}`);
}

function compileHarness() {
  run('swiftc', [
    '-o', swiftHarness,
    path.join(repoRoot, 'scripts/parity-harness.swift'),
    path.join(repoRoot, 'pi-manager/Models.swift'),
    path.join(repoRoot, 'pi-manager/EditingModels.swift'),
    path.join(repoRoot, 'pi-manager/PiScanner.swift'),
    path.join(repoRoot, 'pi-manager/AgentPersistence.swift'),
    path.join(repoRoot, 'pi-manager/ChainPersistence.swift'),
  ]);
}

function setupFixtureEnvironment() {
  const home = path.join(tmpRoot, 'home');
  const project = path.join(tmpRoot, 'project');
  copyDir(path.join(fixturesRoot, 'home'), home);
  copyDir(path.join(fixturesRoot, 'project'), project);
  return { home, project };
}

function swiftJSON(args, env) {
  return JSON.parse(run(swiftHarness, args, { env: { ...process.env, ...env } }));
}

function main() {
  compileHarness();
  const { home, project } = setupFixtureEnvironment();
  const env = { HOME: home };

  const packageSummary = normalizePackageSummary(project);
  const swiftSummary = swiftJSON(['scan', project], env);

  assertEqual('scan-summary', {
    global: swiftSummary.global,
    project: swiftSummary.project,
    effective: swiftSummary.effective,
    chains: swiftSummary.chains,
    settings: swiftSummary.settings,
  }, {
    global: packageSummary.global,
    project: packageSummary.project,
    effective: packageSummary.effective,
    chains: packageSummary.chains,
    settings: packageSummary.settings,
  });

  const agentJSON = path.join(fixturesRoot, 'agent-serialize.json');
  const packageAgent = serializeAgent(packageConfigFromFixture(agentJSON));
  const swiftAgent = run(swiftHarness, ['serialize-agent', agentJSON], { env: { ...process.env, ...env } });
  assertEqual('serialize-agent', swiftAgent, packageAgent);

  const chainJSON = path.join(fixturesRoot, 'chain-serialize.json');
  const chainPayload = JSON.parse(fs.readFileSync(chainJSON, 'utf8'));
  const packageChain = serializeChain({
    name: chainPayload.name,
    description: chainPayload.description,
    source: 'user',
    filePath: '/tmp/fixture.chain.md',
    steps: chainPayload.steps.map((step) => ({
      agent: step.agent,
      task: step.body,
      output: step.outputDisabled ? false : (step.output ?? undefined),
      reads: step.readsDisabled ? false : (step.reads ?? undefined),
      model: step.model ?? undefined,
      skills: step.skillsDisabled ? false : (step.skills ?? undefined),
      progress: step.progress ?? undefined,
    })),
    extraFields: chainPayload.extraFields,
  });
  const swiftChain = run(swiftHarness, ['serialize-chain', chainJSON], { env: { ...process.env, ...env } });
  assertEqual('serialize-chain', swiftChain, packageChain);

  const parsedChainSource = fs.readFileSync(path.join(project, '.pi/agents/fixture-modern.chain.md'), 'utf8');
  const packageParsedChain = parseChain(parsedChainSource, 'project', path.join(project, '.pi/agents/fixture-modern.chain.md'));
  const swiftParsedChain = swiftSummary.chains.find((chain) => chain.name === 'fixture-modern');
  assertEqual('parse-chain-modern', {
    ...swiftParsedChain,
    filePath: normPath(swiftParsedChain.filePath),
  }, {
    name: packageParsedChain.name,
    filePath: normPath(packageParsedChain.filePath),
    source: 'Project',
    description: packageParsedChain.description,
    extraFields: packageParsedChain.extraFields ?? {},
    steps: packageParsedChain.steps.map((step) => ({
      agent: step.agent,
      output: typeof step.output === 'string' ? step.output : null,
      outputDisabled: step.output === false,
      reads: Array.isArray(step.reads) ? step.reads : null,
      readsDisabled: step.reads === false,
      model: step.model ?? null,
      skills: Array.isArray(step.skills) ? step.skills : null,
      skillsDisabled: step.skills === false,
      progress: step.progress ?? null,
      body: step.task ?? '',
    })),
  });

  const baseJSON = path.join(fixturesRoot, 'agent-base.json');
  const editedJSON = path.join(fixturesRoot, 'agent-edited.json');
  const packageOverride = buildBuiltinOverrideConfig(
    packageConfigFromFixture(baseJSON),
    packageConfigFromFixture(editedJSON),
  );
  const swiftOverride = swiftJSON(['builtin-override', baseJSON, editedJSON], env);
  assertEqual('builtin-override', swiftOverride, packageOverride ?? {});

  console.log(`\nAll parity checks passed. Temp dir: ${tmpRoot}`);
}

main();
