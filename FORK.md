# pi-deck — Agent Deck 二开基座

## 关系

| 仓库 | 路径 | 角色 |
|------|------|------|
| **pi-deck**（本仓） | `~/Documents/WorkSpace/Web/pi-deck` | **产品主线**：fork Agent Deck 二开 |
| **pi-app** | `~/Documents/WorkSpace/Web/pi-app` | 对照 / 历史实现，不在本仓合并删改 |
| **upstream** | `a-streetcoder/agent-deck` | 定期 `git fetch upstream` 同步 |

## 分支

- `feat/deck-base` — 二开基线（跟踪 upstream/main 起点）
- 后续功能：`feat/*` 从本分支切出

## 二开优先级（初稿）

1. 品牌：Bundle ID / 显示名 / 图标 / 关于页 — **done（基础）**
2. 关闭或审查 PostHog analytics
3. RPC 安全默认（offline / autoApprove）对齐 pi-app 经验
4. 中文 l10n — **Phase 1–3 done**
5. **移除 GitHub Issues 工作台** — done（侧栏/屏/Composer 附加 Issue/`startIssueSession`/board API；保留 Doctor `gh` 登录与会话 Git commit/push）
6. 从 pi-app port：首条 optimistic、EEXIST、transcript cache、extension chrome 等（按需）

## l10n（Phase 1）

| 项 | 说明 |
|----|------|
| 引擎 | `L10n.swift` + `LanguageStore`（`UserDefaults` key `pi.deck.appLanguage`） |
| 资源 | `agent-deck/en.lproj/Localizable.strings` · `agent-deck/zh-Hans.lproj/Localizable.strings` |
| 切换 | Settings → General → Language（English / 中文），**即时**生效 |
| 已覆盖 | Phase1–3：侧栏/Settings/搜索；Composer/工具栏/会话列表/Activity/Ask；Environment/Doctor；Subagents/Models/Deck agents/Startup/转录显示（Issues 屏已移除） |
| 未覆盖 | Skills/Prompts/Loops/MCP/Extensions/Agents 管理长文案、Git merge 详细说明等 — 继续按屏扩表 |

**加文案**：两端 `.strings` 同步加 key → UI 用 `LanguageStore.shared.t("key")`（View 内需 `@ObservedObject`/`environmentObject` 才能刷新）。

## 构建

- 要求：macOS 26+、Xcode 26+
- `open agent-deck.xcodeproj` → scheme `agent-deck`

## 版权

上游 MIT · Streetcoding Ltd — 保留 LICENSE 与版权声明。

## Brand (本 fork)

| 项 | 值 |
|----|-----|
| 显示名 | Pi Deck |
| Bundle ID | `works.earendil.pi-deck` |
| App Support | `~/Library/Application Support/Pi Deck/` |
| Logs | `~/Library/Logs/Pi Deck/` |
| Sparkle 自动更新 | **关闭**（勿拉官方 appcast） |

改名入口：`agent-deck.xcodeproj` 的 `APP_PRODUCT_NAME` / `PRODUCT_BUNDLE_IDENTIFIER`，以及 `AppBrand.displayName` fallback。
