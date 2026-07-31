# Changelog

## 0.0.9 — 2026-07-31

### Highlights
- **分支切换**：composer 底部分支菜单支持本地 + 远端全量（`git fetch --all --prune`）；点远端分支自动建本地跟踪分支。
- **会话标题只读**：去掉侧栏/会话头手动重命名，标题由 AI 自动生成展示。
- **空 thinking 结束回合**：turn 结束且无最终 message payload 时正确回到 idle，避免一直 Working。

### Fixed / Changed
- `PiAgentComposerViews` + `GitRepositoryService`：`listLocalBranches` / `listRemoteBranches` / `fetchAllRemotes` / `checkoutLocalOrRemoteBranch`
- `PiAgentSessionListViews` / `PiAgentViews`：移除 rename UI 与状态
- thinking-only turn 结束路径（idle recovery）

### Packaging
- `MARKETING_VERSION` **0.0.9**，`CURRENT_PROJECT_VERSION` **9**
- Tag: `v0.0.9`
- Artifacts: `build/Pi-Deck-0.0.9.zip`, `build/Pi-Deck-0.0.9.dmg`（未签名）

### Install (unsigned)
```bash
xattr -cr "/Applications/Pi Deck.app"
```

---

## 0.0.8 — 2026-07-31

### Highlights
- **自动会话标题恢复可用**：标题 helper 不再强制 `model:off`（`grok-4.5` 等推理模型会 400）；改为优先 `minimal` 等可接受 thinking。`Draft ·` 与 `Chat ·` 临时标题均可生成；失败时带上模型错误信息。

### Fixed
- `PiSessionTitleGenerationService.helperRuntimeModelArgument`：隔离 helper 的 thinking 选择
- `AppViewModel` / `PiAgentSessionModels.isProvisionalAutoTitle`：Agent `Chat ·` 会话也参与自动标题
- 同类 helper（avatar / skill 描述 / ship / release notes）同步修正

### Packaging
- `MARKETING_VERSION` **0.0.8**，`CURRENT_PROJECT_VERSION` **8**
- Tag: `v0.0.8`
- Artifacts: `build/Pi-Deck-0.0.8.zip`, `build/Pi-Deck-0.0.8.dmg`（未签名）

### Install (unsigned)
```bash
xattr -cr "/Applications/Pi Deck.app"
```

---

## 0.0.7 — 2026-07-31

### Highlights
- **Composer IME**：模型流式输出重绘时不再覆盖输入框 `string`，避免中文/日文等输入法预编辑与候选被吞。

### Fixed
- `PiAgentDropSafeTextEditor.updateNSView`：`hasMarkedText()` 期间跳过强制赋值；减少每帧重设 font。

### Packaging
- `MARKETING_VERSION` **0.0.7**，`CURRENT_PROJECT_VERSION` **7**
- Tag: `v0.0.7`
- Artifacts: `build/Pi-Deck-0.0.7.zip`, `build/Pi-Deck-0.0.7.dmg`（未签名）

### Install (unsigned)
```bash
xattr -cr "/Applications/Pi Deck.app"
```

---

## 0.0.6 — 2026-07-31

### Highlights
- **Markdown 表格可读性**：圆角边框卡片、表头底色、行/列分隔线、单元格内边距；列宽按内容权重分配（不再强制等分），剩余宽度补给长列并铺满气泡。
- **表格色带对齐**：表头/斑马纹背景铺满外框（去掉左右 gutter 色差）。

### Fixed
- `MarkdownTableView`：等分列宽 → content-weighted；弱网格 → 明确表格 chrome；左侧背景未对齐。

### Packaging
- `MARKETING_VERSION` **0.0.6**，`CURRENT_PROJECT_VERSION` **6**
- Tag: `v0.0.6`
- Artifacts: `build/Pi-Deck-0.0.6.zip`, `build/Pi-Deck-0.0.6.dmg`（未签名）

### Install (unsigned)
```bash
xattr -cr "/Applications/Pi Deck.app"
```

---

## 0.0.5 — 2026-07-31

### Highlights
- **Transcript 气泡宽度（ChatGPT 风格）**：助手/工具卡铺满会话栏（减去操作栏 gutter）；用户气泡仍右对齐，最大宽度比例更低，去掉中间大块留白。

### Fixed
- `PiAgentTranscriptViews` / `NativeBubblePreviewDebug` 气泡布局。

### Packaging
- `MARKETING_VERSION` **0.0.5**，`CURRENT_PROJECT_VERSION` **5**
- Tag: `v0.0.5`
- Artifacts: `build/Pi-Deck-0.0.5.zip`, `build/Pi-Deck-0.0.5.dmg`（未签名）

### Install (unsigned)
```bash
xattr -cr "/Applications/Pi Deck.app"
```

---

## 0.0.4 — 2026-07-31

### Highlights
- **pi CLI 路径持久化**：设置 / Doctor 可「使用此路径 / 检测并保存」；有可执行 preferred path 时跳过 PATH 扫描。
- **pi-web-access 依赖提示**：Extensions bridges 与 Doctor 网络访问说明共用 `~/.pi/web-search.json`；列出 web-access 包时橙色跳过警告。
- **Composer IME**：输入法组字过程中 Return 不发送。

### Fixed
- PiScanner web-search 凭据警告与 Deck 多 provider（Exa/Brave/Tavily）对齐。
- `isDeckSuperseded*` 等启动参数 helper `nonisolated`，避免 MainActor 隔离编译问题。

### Packaging
- `MARKETING_VERSION` **0.0.4**，`CURRENT_PROJECT_VERSION` **4**
- Tag: `v0.0.4`
- Artifacts: `build/Pi-Deck-0.0.4.zip`, `build/Pi-Deck-0.0.4.dmg`（未签名）

### Install (unsigned)
```bash
xattr -cr "/Applications/Pi Deck.app"
```

---

## 0.0.3 — 2026-07-30

### Highlights
- **l10n 运行时加固**：`Localizable.strings` 字典缓存；应用内语言与系统语言不一致时不再整页回退成 key。
- 语言切换强制刷新 UI；修正若干 format key 误用。
- **Composer 文件粘贴**：Finder ⌘C → 输入框 ⌘V 可挂文件/文件夹；兼容 file-reference URL 与绝对路径文本。
- **屏蔽上游 Sparkle**：默认不再检查 `agentdeck.site` 更新；打包禁止注入上游 appcast。

### Fixed
- `fileURLs`：解析 `file:///.file/id=…`、`NSFilenames`、`public.file-url` data/string。
- `DropSafeNSTextView`：⌘V 强制走 `paste`；注册拖拽类型；`pasteAsPlainText` 同路径。
- 纯路径多行文本在存在于磁盘时当作附件。
- `inject-sparkle-info` / `package-app` / `package-dmg`：默认空 feed；禁止 `agentdeck.site`。
- `UpdaterService`：无合法 `SUFeedURL` 或含 `agentdeck.site` 时不启用 Sparkle。

### Packaging
- `MARKETING_VERSION` **0.0.3**，`CURRENT_PROJECT_VERSION` **3**
- Tag: `v0.0.3`
- Artifacts: `build/Pi-Deck-0.0.3.zip`, `build/Pi-Deck-0.0.3.dmg`（未签名）

### Install (unsigned)
```bash
xattr -cr "/Applications/Pi Deck.app"
```

---

## 0.0.2 — 2026-07-30

### Highlights
- **中英本地化大范围推进**：Settings / Doctor / Extensions / Skills / Loops / Agents / Memory / 菜单栏 / 会话与 transcript 等 UI 文案接入 `LanguageStore`。
- **用户资料**：设置里可配置显示名称与头像（含预览裁切），同步到对话气泡。
- **会话标题更稳、更好认**：Draft 失败可重试；标题语言跟随首条用户消息；生成后工具栏/列表仍显示 **项目 · 标题**。

### Added
- 用户显示名称与头像（`AppSettings` + `UserAvatarStore`），头像选择后预览/裁切再保存。
- 会话自动标题：使用应用语言示例规则，并按首条用户消息脚本检测中/英。
- Soft system notice 本地化标签（如 Notify → 通知）与通知图标头。
- Composer 快捷键提示条与 Projects 空态等文案本地化。
- DMG 打包脚本强化（Applications 快捷方式、挂载清理）；README 补充未签名 Gatekeeper `xattr` 说明。

### Changed
- 启动闪屏品牌为 **Pi Deck**（不再显示 Agent Deck wordmark）。
- 移除侧栏 **Environment** 入口。
- 默认不再自动注入 Codex Computer Use MCP。
- 扩展设置、循环编辑器、技能库、工具栏等大量硬编码英文改为 l10n keys。

### Fixed
- 自动会话标题在 Draft 状态下失败后可重试，不再永久卡在 `Draft · …`。
- GUI 下 Connect Provider 目录解析 mise 的 `node`/`pi` PATH。
- Compact 后保留 context usage 计量显示。
- Extension soft notice 卡片宽度与回复气泡对齐。
- 自动生成标题后工具栏/紧凑列表仍可看出所属项目（`chromeTitle` / 项目副标题）。

### Packaging
- `MARKETING_VERSION` **0.0.2**，`CURRENT_PROJECT_VERSION` **2**
- Tag: `v0.0.2`
- Artifacts: `build/Pi-Deck-0.0.2.zip`, `build/Pi-Deck-0.0.2.dmg`（未签名）

### Install (unsigned)
```bash
xattr -cr "/Applications/Pi Deck.app"
```

---
