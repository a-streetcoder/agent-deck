# 三栏缩放统一重构计划

## 目标

1. 拖动分栏线不卡、不反推、宽度跟手
2. 拖动中 transcript 只有气泡卡片横向跟随，不做任何高度重算 / 滚动补偿
3. 去掉旧的宽度动画 / 预判链路，只留一条宽度更新主路径

## 改动范围

两个文件：
- `agent-deck/PiAgentRepoReviewViews.swift`
- `agent-deck/PiAgentViews.swift`

## 当前问题清单

| # | 现象 | 根因 |
|---|------|------|
| 1 | 拖到最小时两边反向撑开 | `effectiveMaxReviewWidth` 用硬 min 加总，host 不足时 layout 夹逼，HStack 行为不稳定 |
| 2 | 拖动不跟手 | `DragGesture` 中使用 `effectiveMaxReviewWidth` 把 drag 值经过两次 clamp 再写回，引入滞后 |
| 3 | 气泡卡片和正文联动缩放 + 抖动 | `frameDidChange → updateColumnWidthIfNeeded` 和 `liveResize → applyLiveTranscriptColumnWidth` 两路同时跑，各自调 `applyWidthOnlyToVisibleCells` |
| 4 | 拖动中上下滚动 / 重叠 | `scheduleVisibleWidthReconfigure` 在 settle 后调 `reconfigureAllVisibleCells`，触发行高重算和 anchor 补偿 |
| 5 | 旧代码残留 | `postTranscriptWidthAnimation` 方法体还在文件里但无人调用；`guard hostWidth > 1` 重复两次 |

## 数据流（当前 vs 目标）

### 当前（3 条宽度更新链同时存在）

```
DragGesture
  └→ reviewPanelWidth 变化
       └→ body 重渲染 → chat 列宽变
            ├→ frameDidChange → updateColumnWidthIfNeeded()
            │    └→ contentWidth = 新宽
            │    └→ scheduleVisibleWidthReconfigure()  ← 链 A
            │         ├→ trackLive? → applyWidthOnlyToVisibleCells()
            │         └→ settle → reconfigureAllVisibleCells()  ← 触发高度重算
            │
            ├→ liveResize notification → applyLiveTranscriptColumnWidth()  ← 链 B
            │    └→ contentWidth = 新宽
            │    └→ applyWidthOnlyToVisibleCells()
            │    └→ isFinal? → reconfigureAllVisibleCells()  ← 触发高度重算
            │
            └→ onPreferenceChange → chatColumnWidth 更新  ← 链 C（纯读数）
```

### 目标（1 条主路径）

```
DragGesture
  └→ reviewPanelWidth 变化
       └→ body 重渲染 → chat 列宽变
            ├→ frameDidChange → updateColumnWidthIfNeeded()
            │    └→ 检测到 isLiveResizing → 跳过（由 liveResize 接管）
            │
            └→ liveResize notification → applyLiveTranscriptColumnWidth()  ← 唯一生效路径
                 ├→ contentWidth = 新宽
                 ├→ applyWidthOnlyToVisibleCells()（只改 cardWidth constraint）
                 └→ isFinal? → 一次 reconfigureAllVisibleCells()
```

## 实施步骤

### Step 1: 去掉三栏 host 里的残留代码

**文件**: `PiAgentRepoReviewViews.swift`

- [ ] 删除重复的 `guard hostWidth > 1 else { return }`
- [ ] 删除整个 `postTranscriptWidthAnimation(expanding:)` 方法体（留空或注释掉）
- [ ] 删除 `animateVisibleBubbleWidths` 在 PiAgentViews 中的方法体（已无调用方，但方法还在）

### Step 2: 重构 host 的宽度约束模型

**文件**: `PiAgentRepoReviewViews.swift`

`effectiveMaxReviewWidth` 当前用硬 min 加总：
```swift
let reserved = clampedSidebarWidth + handleWidth + chatMin + handleWidth
let fromHost = max(reviewMin, host - reserved)
return min(reviewMax, fromHost)
```

**改为**：host 不足时 review 优先退让，review 退到 min 后 sidebar 再退让：

```swift
private var effectiveMaxReviewWidth: CGFloat {
    let host = hostWidth > 1 ? hostWidth : 1400
    let handles = isReviewExpanded ? handleWidth * 2 : handleWidth
    // sidebar stays in its range; review gets remaining after sidebar+chatMin
    let available = host - clampedSidebarWidth - handles
    // review max = what's left after chatMin, capped by reviewMax
    return min(reviewMax, max(reviewMin, available - chatMin))
}
```

同时 `handleReviewDragChanged` 不再用 `effectiveMaxReviewWidth` 做 clamp，改用在 `withTransaction` 里直接用 `next` 值，只保 `reviewMin` 和 `reviewMax` 的硬边界：

```swift
// 只用 reviewMin/reviewMax 钳制；host 不足时由 SwiftUI layout 自然压缩
let clamped = min(reviewMax, max(reviewMin, next))
```

### Step 3: 加 isLiveResizing 闸门

**文件**: `PiAgentViews.swift`（Coordinator 内）

- [ ] 新增 `var isLiveResizing = false`
- [ ] `applyLiveTranscriptColumnWidth` 开头设 `isLiveResizing = true`，`isFinal` 时在 return 前设回 `false`
- [ ] `updateColumnWidthIfNeeded` 开头加 `guard !isLiveResizing else { return }`

这样拖动期间只有 `liveResize` 通知在改宽度，`frameDidChange` 这条链路自动静默。

### Step 4: 拖动期间禁止高度重算和 full reconfigure

**文件**: `PiAgentViews.swift`

- [ ] `applyLiveTranscriptColumnWidth` 中 `!isFinal` 分支：
  - 保留 `contentWidth = target`
  - 保留 `tableView.tableColumns.first?.width = target` + `sizeLastColumnToFit`
  - 保留 `applyWidthOnlyToVisibleCells`
  - **去掉** `estimateByID.removeAll()`（拖动中不需要重建估算）
- [ ] `isFinal` 分支：
  - 做 `reconfigureAllVisibleCells()`（仅此一次）
  - 清理 `estimateByID`

### Step 5: scheduleVisibleWidthReconfigure 加闸门

**文件**: `PiAgentViews.swift`

- [ ] 方法开头加 `guard !isLiveResizing else { return }`
- [ ] 去掉 `trackLive` 路径里的 `reconfigureAllVisibleCells()`，只保留 `applyWidthOnlyToVisibleCells`

这样窗口 resize / sidebar 拖动时的 settle 路径也不会在拖动期间触发高度重排。

### Step 6: 收口右侧拖条命中层

**文件**: `PiAgentRepoReviewViews.swift`

- [ ] Review columnHandle 已有的 `.padding(.horizontal, 6)` + `.contentShape(Rectangle())` + `.zIndex(30)` 保留
- [ ] Review 面板 `.zIndex(5)` 保留
- [ ] 如果体验还不够，再加一个透明 overlay handle 浮在 HStack 最上层，独立捕获 drag

### Step 7: 编译 + 回归验证

- [ ] `xcodebuild agent-deck BUILD SUCCEEDED`
- [ ] 手动验证：
  - 拖右侧分栏线：宽度跟手，不卡
  - 拖到最小 / 最大：不撑开两边
  - 中间栏气泡：只做横向跟随，无高度跳动 / 上下滚动
  - 侧栏拖动：同理
  - 开关 Review：过渡自然

## 不改的范围

- transcript 的 `apply()` 流程（内容更新、流式推送）不动
- `columnHandle` 的整体手势结构不动
- 持久化（UserDefaults sidebarWidth / reviewPanelWidth）不动
- `onChange(of: hostWidth)` 的 clamp 调用保留，但约束公式已更新
