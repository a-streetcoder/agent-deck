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

1. 品牌：Bundle ID / 显示名 / 图标 / 关于页
2. 关闭或审查 PostHog analytics
3. RPC 安全默认（offline / autoApprove）对齐 pi-app 经验
4. 中文 l10n
5. 从 pi-app port：首条 optimistic、EEXIST、transcript cache、extension chrome 等（按需）

## 构建

- 要求：macOS 26+、Xcode 26+
- `open agent-deck.xcodeproj` → scheme `agent-deck`

## 版权

上游 MIT · Streetcoding Ltd — 保留 LICENSE 与版权声明。
