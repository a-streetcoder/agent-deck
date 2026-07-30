# Pi Deck

<p align="center">
  <strong>基于 <a href="https://github.com/a-streetcoder/agent-deck">Agent Deck</a> 的 Pi 原生 macOS 工作台（二开 / fork）。</strong><br>
  继续使用你本机安装的 <a href="https://github.com/earendil-works/pi">Pi</a> CLI（JSONL RPC），在 Deck 之上做品牌、中文化、Issues 精简与扩展体验改造。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/base-Agent%20Deck-blue" alt="Based on Agent Deck">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  <img src="https://img.shields.io/badge/macOS-26%20Tahoe-black?logo=apple" alt="macOS 26 Tahoe">
  <img src="https://img.shields.io/badge/Built%20with-Swift%206-orange?logo=swift" alt="Swift">
  <img src="https://img.shields.io/badge/l10n-en%20%7C%20zh--Hans-lightgrey" alt="l10n">
</p>

| | |
|---|---|
| **本仓** | [mengeric/pi-deck](https://github.com/mengeric/pi-deck) · 分支 `feat/deck-base` |
| **上游** | [a-streetcoder/agent-deck](https://github.com/a-streetcoder/agent-deck)（`upstream`，只读同步） |
| **产品名** | Pi Deck |
| **Bundle ID** | `works.earendil.pi-deck` |
| **要求** | macOS 26+ · Apple Silicon · Xcode 26+ · 本机 `pi` CLI |

更细的二开笔记见 [`FORK.md`](FORK.md)。上游概念文档仍在 [`agent-deck-documentation/`](agent-deck-documentation/)。

---

## 与上游 Agent Deck 的关系

Pi Deck **不是**从零写的客户端，而是在 **Agent Deck** 源码基线上做二次开发：

- 保留：Pi JSONL RPC 会话、原生 transcript、Skills / MCP / Prompts / Loops / Extensions、Memory、Subagents、Doctor、项目侧栏等核心能力。
- 改造：品牌与数据目录、中英 l10n、去掉 GitHub Issues 工作台与 Doctor 里的 GitHub 诊断、扩展 slash / notify 体验、web 搜索多供应商、Markdown 代码块复制等。
- 发布：关闭对上游 Sparkle appcast 的自动更新（避免误拉官方包）。

上游贡献与版权：MIT · Streetcoding Ltd — 见 [`LICENSE`](LICENSE)。

---

## 本 fork 相对 Agent Deck 的改动清单

以下按主题汇总 **`feat/deck-base` 上已落地的差异**（相对上游基线 commit 之后的提交；thinking 合并实验已 **revert**，不列入产品行为）。

### 1. 品牌与运行身份

| 项 | 上游 Agent Deck | Pi Deck |
|----|-----------------|---------|
| 显示名 | Agent Deck | **Pi Deck** |
| Bundle ID | 上游标识 | **`works.earendil.pi-deck`** |
| Application Support | Agent Deck | **`~/Library/Application Support/Pi Deck/`** |
| Logs | Agent Deck | **`~/Library/Logs/Pi Deck/`** |
| Sparkle 自动更新 | 官方 appcast | **关闭**（`SUEnableAutomaticChecks = NO`，清空 feed） |
| 品牌字体 | Kemco Pixel 等展示字体 | **系统 UI 字体**，去掉像素风 brand 字 |

相关提交：`c2c7bb9` rebrand · `503f50c` system UI font。

### 2. 国际化（en / zh-Hans）

- 引擎：`L10n.swift` + `LanguageStore`（`UserDefaults`：`pi.deck.appLanguage`）。
- 资源：`agent-deck/en.lproj/Localizable.strings`、`agent-deck/zh-Hans.lproj/Localizable.strings`。
- 设置：Settings → General → **Language**（English / 中文），即时刷新；菜单栏 Settings 下亦有 Language 子菜单。

| Phase | 覆盖范围 | 代表提交 |
|-------|----------|----------|
| 1 | 侧栏、Settings、基础 chrome | `f50cecb` |
| 2 | Composer、Agent 工具栏、Doctor、Environment | `58b8b40` |
| 3 | Subagents、Models、Startup、显示选项 | `04e38d7` |
| 4 | Skills / MCP / Prompts / Loops / Extensions / Agents 管理页 | `cbedbd4` |
| 5 | Skill Import、Loop Launch 表单与 info | `45b497c` |
| 6 | 项目 Memory 屏与工具栏 | `ab89368` |
| 菜单/快捷键 | `AgentDeckCommands`、Shortcuts 目录 | `da5b811` |
| Sessions 面板 | Coding Agent 拉起面板与会话列表文案 | `a7e0fc3` |

### 3. 移除 GitHub Issues 工作台与诊断精简

**产品决策：不再提供「从 GitHub Issue 开会话 / Issues 看板」工作流。**

| 变更 | 说明 |
|------|------|
| 删除 Issues UI / 服务 | `IssuesScreen`、`GitHubIssuesViews`、Issue 搜索/服务、`PiIssuePromptBuilder` 等 |
| 侧栏 | 去掉 Issues 入口 |
| 会话创建 | 不再 `createSession(issue…)`；`issueNumber` / `issueURL` 仅历史 JSONL 解码 |
| 时间线 | 历史 issue 附件可解码，**不再展示 issue chip / #编号标题** |
| 死代码 | 去掉无调用的 `GitHubAPIClient`、board REST 模型、ConnectionViews 等 |
| Doctor / Onboarding | **移除 GitHub 登录/连接诊断**与 setup 门禁 |
| 菜单 | 「GitHub」→ **Git**（保留 Refresh / Commit / Push 等仓库能力） |
| 刻意保留 | 本地 git commit/push、Skill 侧 GitHubRemote 解析、历史 `PiAgentIssueAttachment` Codable |

代表提交：`151b610` · `5eb8482` · `86f1a2c` · `b326f8f` · `1b6cc4c`。

### 4. Pi 扩展加载与模型供应商

| 变更 | 说明 |
|------|------|
| `--no-extensions` + 显式注入 | 关闭 Pi 环境 ambient 扩展发现，由 Deck 控制加载顺序 |
| 早期注入 **model provider packages** | 如 `pi-grok-cli` / `pi-xai-oauth`，避免 `Unknown provider` |
| 跳过 Deck 已内置的包 | 如 `pi-ask-user`、`pi-web-access`，避免 `ask_user` / `web_search` 工具名冲突 |
| 用户扩展模式 | **Use my extensions** 时再加载用户勾选的扩展（如 `pi-blackhole`）；默认 managed 模式不加载 |

代表提交：`830744d` · `3fdc7ca`。

### 5. 内置 Web Search bridge（多供应商）

- 上游内置桥偏 Exa + `EXA_API_KEY`。
- Pi Deck：与 `pi-web-access` 对齐，支持 **Exa / Brave / Tavily**。
- 凭证：环境变量或 **`~/.pi/web-search.json`**（亦尊重 `PI_CODING_AGENT_DIR` / XDG）。
- 供应商优先级：工具参数 → config `searchProvider` → `provider` → 默认 Exa（且需对应 key）。
- Doctor / Extensions 屏文案同步为多供应商。

代表提交：`cf197e9`。

### 6. 扩展 UI：Notify / Status / Widget

| 阶段 | 行为 |
|------|------|
| 初版 | 将 notify 等写入 transcript（后调整） |
| 中间 | 短暂改为 ephemeral 弹窗 |
| **当前** | **软系统通知卡片**嵌在时间线内（Claude 风格 soft notice）：Notify / Compaction / Status / Widget |

其它：

- 连续 **相同 title+body** 的 soft notice **去重**，不叠第二张。
- soft notice **不驱动** 底部 “Processing update” 条。
- 纯 slash 用户消息（如 `/blackhole-memory status`）**不写入** Deck transcript 用户气泡。

代表提交：`c6c9ebf` · `5c8ad57` · `2efbca2` · `30c2bbb` · `8af3156`。

### 7. 扩展 Slash 命令（`get_commands`）

- 会话启动后 RPC `get_commands` → 解析为 `PiRuntimeSlashCommand`（name / description / source）。
- 写入 session：`runtimeSlashCommands` + `commandInvocations`。
- `/` 面板合并扩展命令：分区 **Commands**，`scopeLabel: Extension`。
- 选中 **Command（含 Extension）**：填入可编辑文本 **`/name `**（可继续输参数再发），**不**用中间 chip、**不**立即发送。
- Skill / Prompt 仍可走既有 chip 路径。

代表提交：`a3ad4cc` · `26f6162`。

### 8. Thinking / 文案清洗

| 变更 | 说明 |
|------|------|
| `TextSanitizer` | 去 ANSI、清洗 “Thinking:” 装饰前缀；thinking 与 answer 均 sanitize |
| 落盘 | `message_end` 时尽量持久化 reasoning / thinking entry |
| 展示 | transcript / native bubble 走 sanitizer |
| 实验 | thinking 嵌进 assistant 卡片 + 折叠 disclosure — **已全部 revert**，当前仍为 **独立 thinking 卡 + 独立 reply 卡** |

代表提交：`5a1f04b`；revert：`b0baf8a` · `523a719`。

### 9. Sessions 面板 UX

- 默认 **展开** Sessions（Coding Agent 拉起面板）。
- 回到 Agent 侧栏时确保面板展开。
- 面板与会话列表 chrome 走 l10n。

代表提交：`a411a5b` · `a7e0fc3`。

### 10. Markdown 代码块

- 原生 fence 代码块 **右上角复制按钮**（`doc.on.doc` → 点击后短暂 `checkmark`）。
- 流式 in-place 更新时复制内容与 fence 正文同步。

代表提交：`a6b5111`。

### 11. 刻意未改 / 仍跟上游的部分

- 核心 RPC 会话模型、native transcript 布局引擎、Memory 存储与 embedding 召回架构、Subagent 运行时主体。
- 上游文档目录名仍为 `agent-deck-documentation/`（内容多仍写 Agent Deck 产品名，阅读时按 Pi Deck 品牌理解即可）。
- PostHog 集成代码可能仍在树内；Debug 构建行为与上游类似 — 生产策略可按需再关。

---

## 功能概览（继承自 Agent Deck）

- Pi 会话：content-hugging 消息卡、工具调用、计划、附件、steering、会话级 draft。
- 资源：Agents / Skills / Prompts / Slash / MCP / Extensions，按项目分配。
- Subagents、Loop、项目 Markdown Memory。
- Models / providers、环境变量与 Doctor / Onboarding。
- 会话侧 **本地 Git** commit / push / 变更快照（无 Issues 看板）。

---

## 构建与运行

```bash
git clone https://github.com/mengeric/pi-deck.git
cd pi-deck
git checkout feat/deck-base
open agent-deck.xcodeproj
```

Debug 构建（无签名）：

```bash
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO build
```

Release 本地包（无 Developer ID 时同样可关签名）：

```bash
./scripts/build-pi-deck-app.sh
# 产物：build/Pi-Deck.app
```

需要 **Developer ID 签名** 的 export 仍可用上游 `scripts/package-app.sh`（需设置 `DEVELOPER_ID_APPLICATION` 等），产物名请改为 Pi Deck。

发行目录示例（版本号随 tag）：

```bash
./scripts/build-pi-deck-app.sh
# build/Pi-Deck.app
# build/Pi-Deck-0.0.1.dmg
# build/Pi-Deck-0.0.1.zip
```

### 未签名包与 Gatekeeper

当前公开构建多为 **无 Developer ID / 未公证**。从 DMG 或 zip 装到 `/Applications` 后，若系统提示「无法验证开发者」或打不开，在终端清除隔离属性：

```bash
xattr -cr "/Applications/Pi Deck.app"
```

然后再次双击打开；仍被拦时可 **右键 App → 打开** 确认一次。本机 `xcodebuild` 直接产物一般不受此影响。

> 同步上游：`git fetch upstream` 后按需 rebase / cherry-pick；**不要** `push` 到 `upstream`（已配置 `no_push`）。

---

## 配置提示

| 场景 | 建议 |
|------|------|
| 自定义模型包（如 grok-cli） | 确保包在 `~/.pi/.../packages`；Deck 会在 `--no-extensions` 后 early-load provider 包 |
| 用户扩展（blackhole 等） | Extensions → **Use my extensions** 并勾选；**新开会话** 后 `/` 才有扩展命令 |
| Web search | `EXA_API_KEY` / `BRAVE_API_KEY` / `TAVILY_API_KEY` 或 `~/.pi/web-search.json` |
| 语言 | Settings → Language |

---

## License

MIT License. See [`LICENSE`](LICENSE).

本项目基于 [Agent Deck](https://github.com/a-streetcoder/agent-deck)（MIT）。Pi Deck 为独立 fork，与上游发行版无自动更新关系。
