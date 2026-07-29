# pi-deck — Agent Deck 二开基座

完整产品说明与 **相对上游的改动清单** 见根目录 [`README.md`](README.md)。

## 关系

| 仓库 | 路径 | 角色 |
|------|------|------|
| **pi-deck**（本仓） | `~/Documents/WorkSpace/Web/pi-deck` | **产品主线**：fork Agent Deck 二开 |
| **pi-app** | `~/Documents/WorkSpace/Web/pi-app` | 对照 / 历史实现，不在本仓合并删改 |
| **upstream** | `a-streetcoder/agent-deck` | 定期 `git fetch upstream` 同步（`pushurl = no_push`） |
| **origin** | `mengeric/pi-deck` | 推送目标 |

## 分支

- `feat/deck-base` — 二开主线（跟踪 upstream 起点 + 本 fork 全部产品改动）
- 后续功能：`feat/*` 从本分支切出

## 二开优先级（状态）

1. 品牌：Bundle ID / 显示名 / 数据目录 / 关 Sparkle — **done**
2. 中文 l10n Phase 1–6 + 菜单 + Sessions — **done**（深层 Agents 编辑器等可继续）
3. 移除 GitHub Issues 工作台 + 死代码 + Doctor GitHub 诊断 — **done**
4. 扩展加载：provider 包 early-load、跳过 Deck 自有包 — **done**
5. Web search Exa/Brave/Tavily + `~/.pi/web-search.json` — **done**
6. Extension notify soft card、slash 扩展命令、代码块复制 — **done**
7. 关闭或审查 PostHog analytics — **待定**
8. 从 pi-app port：首条 optimistic、EEXIST、transcript cache 等 — **按需**

## Brand

| 项 | 值 |
|----|-----|
| 显示名 | Pi Deck |
| Bundle ID | `works.earendil.pi-deck` |
| App Support | `~/Library/Application Support/Pi Deck/` |
| Logs | `~/Library/Logs/Pi Deck/` |
| Sparkle | **关闭** |

## 构建

```bash
open agent-deck.xcodeproj   # scheme: agent-deck
./scripts/build-pi-deck-app.sh   # → build/Pi-Deck.app
```

## 版权

上游 MIT · Streetcoding Ltd — 保留 LICENSE 与版权声明。
