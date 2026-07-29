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
4. 中文 l10n — **Phase 1–4 done**
5. **移除 GitHub Issues 工作台** — done；**死代码清理** — API/ConnectionViews/board 模型/token；`createSession` 不再写 issue 字段；UI 不再展示 issueNumber / issue chip（JSON 仍可解码）；菜单改 **Git**（commit/push）；Doctor/Onboarding 文案仅保留 commit/push
6. 从 pi-app port：首条 optimistic、EEXIST、transcript cache、extension chrome 等（按需）

## l10n（Phase 1）

| 项 | 说明 |
|----|------|
| 引擎 | `L10n.swift` + `LanguageStore`（`UserDefaults` key `pi.deck.appLanguage`） |
| 资源 | `agent-deck/en.lproj/Localizable.strings` · `agent-deck/zh-Hans.lproj/Localizable.strings` |
| 切换 | Settings → General → Language（English / 中文），**即时**生效 |
| 已覆盖 | Phase1–4：侧栏/Settings/Composer/Doctor；Subagents/Models/Startup；**Skills/MCP/Prompts/Loops/Extensions/Agents 管理高频** |
| 未覆盖 | Loop 启动器细文案、Skill Import 全量、Agents 编辑器深层、Git merge 详细说明等 — 继续按屏扩表 |

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
