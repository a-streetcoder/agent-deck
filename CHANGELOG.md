# Changelog

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

## Unreleased

### Improved
- （占位：下一版变更写在此节）

---

## 0.0.1

Initial Pi Deck fork baseline (see tag `v0.0.1` / README).
