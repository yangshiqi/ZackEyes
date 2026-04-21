# Notch Visibility Toggle — Design

**状态**: 设计定稿，待实现
**分支**: `feat/notch-visibility-toggle`
**日期**: 2026-04-21

## 动机

当前 ZackEyes 的灵动岛（真刘海路径 + 模拟刘海路径）在 compact 状态始终可见。部分用户反馈：

- 平时没有 Claude Code 活动时不想看到顶部那颗 220×32 的药丸（模拟刘海路径）
- 真刘海用户在 session 活跃时会在刘海区显示 buddy 动画 / 状态点，有些用户只想事件发生时才看到

诉求是二值选择：**常驻**（当前行为）或 **隐藏**（平时不显示，仅事件 / 快捷键 / 菜单栏点击时弹出）。

## 目标 & 非目标

**In scope**:
- 新增一个可见性设置，持久化到 `~/.zackeyes/config.json`
- 两条路径（`NotchWindowController` + `SimulatedNotchController`）都遵守设置
- 菜单栏右键菜单 / 真刘海 gear 菜单新增一项 checkmark 切换项（同一份 `StatusBarMenu` 构建）
- 事件触发 `forceUiExpand()`（PermissionRequest / 错误 / welcome）时绕过可见性设置
- 顺便把菜单栏图标从 SF Symbol `sparkles` 换成 `star.fill`（对齐 app logo 的五角星主视觉）

**Out of scope**:
- 三档可见性（如"有 session 时显示"的 auto 档）—— YAGNI
- Per-screen / per-session 可见性
- 配置迁移脚本（无旧字段 = `.always` 默认值，零破坏）
- 切换可见性用的新快捷键（现有展开快捷键继续生效）
- 菜单栏图标的精修矢量方案（`star.fill` 先用，后期可升级到自定义 PDF）
- 任何 Bridge / Socket / Hook 层改动

## 数据模型

### `NotchVisibility` 枚举

位置：`Sources/AppLib/Config/NotchVisibility.swift`

```swift
public enum NotchVisibility: String, Codable, Sendable {
    case always  // 默认，当前行为
    case hidden  // 平时不显示，仅事件 / 快捷键 / 菜单栏点击弹出
}
```

### `ConfigStore` 扩展

**存储位置**：`~/.zackeyes/config.json`（沿用）

**JSON 新字段**（在 `ConfigWrapper` 里）：
```swift
private struct ConfigWrapper: Codable {
    var hotkey: HotKeyConfig
    var githubToken: String?
    var theme: BuddyTheme?
    var notificationSound: String?
    var notchVisibility: String?  // 新增 —— nil 等同 "always"
}
```

**新 API**：
```swift
public func loadNotchVisibility() -> NotchVisibility
public func saveNotchVisibility(_ visibility: NotchVisibility)
```

实现模式完全对齐 `loadTheme` / `saveTheme`：读旧 wrapper → 改单字段 → 原子写回，保证不破坏 hotkey / theme / githubToken / notificationSound。缺字段或解析失败时返回 `.always`。

## 行为规则（visibility == `.hidden`）

| 触发源 | 行为 |
|---|---|
| 平时（无事件、无用户操作） | 面板 `panel.orderOut(nil)`，完全从屏幕上移除——不占视觉空间、不在 Mission Control 中出现、不接收任何鼠标事件 |
| 鼠标 hover（模拟刘海的屏幕顶部 / 真刘海的刘海行） | 无效。两个 controller 的 mouse move handler 在入口 early-return |
| 全局快捷键（默认 `⌘⇧/`） | 先 `panel.orderFrontRegardless()` 把面板放回屏幕，再走正常的 `setMode(.full)` / `updatePanelState(.expanded)` |
| 菜单栏图标左键点击 | 同上（`onIconClick` 回调已存在，内部做同样的"先 orderFront 再 expand"） |
| `forceUiExpand()`（PermissionRequest / 错误 / welcome） | 同上，**绕过可见性设置**。权限审批永不被屏蔽——否则会卡住用户的 Claude Code 命令 |
| collapse（点外部 / 鼠标离开 / 超时 / welcome 定时器） | 按原逻辑 `setMode(.compact)` / `updatePanelState(.compact)`，然后判断当前 visibility；若为 `.hidden` 立即 `panel.orderOut(nil)` 再次下屏 |

**不变的铁律**（CLAUDE.md 中已登记）：
- NSPanel 的 `nonActivatingPanel` / `canBecomeMain = false` / window level / `ignoresMouseEvents`（在 compact 时）等安全属性全部保持
- 一旦 collapse 立即下屏，不做"保留几秒 pill"折中，语义必须锐利
- 事件路径（`forceUiExpand`）永远优先于可见性设置

## UI 入口

修改 `Sources/AppLib/MenuBar/StatusBarMenu.swift` 的 `build()`。新增菜单项位置：

```
About
Change Hotkey…
✓ Show Dynamic Island       ← 新增
Theme ▶
───────
Quit ZackEyes
```

- `item.state = .on` 当 `visibility == .always`，`.off` 当 `.hidden`
- `target = self`，`action = #selector(toggleVisibilityClicked(_:))`
- 点击处理：翻转 → `ConfigStore().saveNotchVisibility(newValue)` → `NotificationCenter.default.post(name: .notchVisibilityChanged, object: nil, userInfo: ["visibility": newValue])`

**为什么二值 checkmark 而不是子菜单 + 两个 radio**：二值开关用 checkmark 是 macOS 标准约定（参考 "Show in Menu Bar"），更少点击、视觉更轻。

**覆盖面**：`StatusBarMenu.build()` 是两条路径共享的菜单源——真刘海的 gear、模拟刘海的 gear、菜单栏图标右键全部 `menu.popUp(statusBarMenu.build())`，所以此处加一次全覆盖。

## 状态传播

### 新通知名

```swift
// 某个合适的扩展位置（与 .hotkeyConfigChanged 同一个文件 / 同一种风格）
extension Notification.Name {
    static let notchVisibilityChanged = Notification.Name("notchVisibilityChanged")
}
```

### `AppDelegate.applicationDidFinishLaunching`

1. 启动时 `let visibility = ConfigStore().loadNotchVisibility()`
2. 创建 controller 后调用 `controller.applyVisibility(visibility)`——让 controller 在启动时就按设置摆好面板位置
3. 注册通知观察者：
```swift
NotificationCenter.default.addObserver(
    forName: .notchVisibilityChanged,
    object: nil,
    queue: .main
) { [weak self] notification in
    let visibility = notification.userInfo?["visibility"] as? NotchVisibility ?? .always
    Task { @MainActor in
        self?.windowController?.applyVisibility(visibility)
        self?.simulatedNotch?.applyVisibility(visibility)
    }
}
```

### 两个 controller 新增方法

**`SimulatedNotchController.applyVisibility(_:)`** 和 **`NotchWindowController.applyVisibility(_:)`**：

```swift
private var visibility: NotchVisibility = .always

public func applyVisibility(_ v: NotchVisibility) {
    visibility = v
    guard let panel = panel else { return }
    if v == .hidden && /* 当前不在展开态 */ {
        panel.orderOut(nil)
    } else {
        panel.orderFrontRegardless()
    }
}
```

"当前不在展开态" 判断：
- `SimulatedNotchController`：`mode != .full`
- `NotchWindowController`：`currentState != .expanded`

### `setMode(.compact)` / `updatePanelState(.compact)` 末尾

两个 controller 在回到 compact 的路径末尾各加：
```swift
if visibility == .hidden {
    panel?.orderOut(nil)
}
```

### `forceExpand()` / 快捷键 handler / 菜单栏 onIconClick 开头

```swift
if let panel, !panel.isVisible {
    panel.orderFrontRegardless()
}
// 然后走原本的 setMode(.full) / updatePanelState(.expanded)
```

### hover 短路

- `SimulatedNotchController.handleMouseMove(_:)`：入口加 `guard visibility != .hidden else { return }`
- `NotchWindowController.handleMouseMoved(_:)`：`.compact` 分支加同样守卫

hover 路径被短路后，鼠标移到屏幕顶部不会召唤出 hidden 的面板。召回只能走快捷键 / 菜单栏 / 事件。

## 菜单栏图标

修改 `Sources/AppLib/MenuBar/MenuBarFallback.swift` 的 `updateIcon(for:)`：

```swift
// Before
NSImage(systemSymbolName: "sparkles", accessibilityDescription: "ZackEyes")

// After
NSImage(systemSymbolName: "star.fill", accessibilityDescription: "ZackEyes")
```

**为什么 `star.fill`**：
- 对齐 app icon 的五角星主视觉（Rage Against the Machine 风格 logo）
- SF Symbol 零资源文件、自动 retina / 亮暗模式适配、默认 `isTemplate = true`
- 现有的状态着色（`.waiting` 橙 / `.working` 青 / `.idle` 无染色）继续生效

**后续升级路径**（不在本次 scope）：如果想要更贴近 logo 里那颗特定比例的星，可导出矢量 PDF 放到 `Resources/`，用 `NSImage(named:)` 替换 SF Symbol。迁移成本为零。

## 边界情况

1. **多屏 / 外接显示器拔插** — `didChangeScreenParametersNotification` 在两个 controller 里已经监听并重建面板。重建后的 `createPanel()` 末尾读当前 `visibility`，`.hidden` 时 `orderOut`，`.always` 时 `orderFrontRegardless`
2. **welcome onboarding** — `maybeShowWelcome()` 走 `forceUiExpand()`，自动覆盖 hidden；3 秒后 `forceUiCompact()` 触发 compact collapse 回调，自动 `orderOut`。用户看到一次 welcome 后回到隐身
3. **hotkey 录制窗口** — `HotkeyRecorderWindow` 是独立 NSPanel，不受影响
4. **第一次从 `.always` 切到 `.hidden` 时** — 如果当前面板正处于 `.compact`，立即 `orderOut`；如果正处于 `.full`（很不常见，用户打开菜单时可能展开），不动，等下次 collapse 自然触发 `orderOut`
5. **从 `.hidden` 切回 `.always`** — 立即 `orderFrontRegardless()`，`setMode(.compact)`（模拟刘海）或保持现状（真刘海 compact 就是默认）

## 测试

### 单元（`ConfigStoreTests`）

- 新增 `testVisibilityRoundtrip`：写入 `.hidden` → 读回是 `.hidden`
- 新增 `testVisibilityDefault`：config.json 无此字段时 `loadNotchVisibility()` 返回 `.always`
- 新增 `testVisibilityPreservesOtherFields`：保存 visibility 不应破坏 hotkey / theme / githubToken / notificationSound
- 回归 `testThemeRoundtrip` / `testHotkeyRoundtrip`：确认新增字段没破坏旧读写

### 手动验证

1. **切到 hidden → 面板消失**：菜单栏点 "Show Dynamic Island"（去掉 ✓），确认两种屏幕（带刘海 / 不带）都看不到任何 compact 内容
2. **hover 不召回**：鼠标移到屏幕顶部，面板不出现
3. **快捷键能召回**：按 `⌘⇧/`（或用户配置的键），面板展开
4. **菜单栏点击能召回**：左键点菜单栏图标，面板展开
5. **PermissionRequest 能召回**：触发一次权限请求（`echo '...' | bridge --event PermissionRequest`），面板弹出
6. **处理完回隐身**：权限审批后，鼠标离开面板 / 点外部，面板 collapse 并再次 orderOut
7. **重启持久化**：Quit + 重启，hidden 状态保持
8. **切回 always**：菜单栏点回 "Show Dynamic Island"（✓ 回来），compact pill 立即出现
9. **菜单栏图标换星形**：视觉确认 `star.fill`，亮暗模板着色正常，状态（橙/青/无）正常

## Known Risks

- **真刘海首次启动顺序**：`createPanel()` 如果在 `applyVisibility()` 之前跑完，就会先 `orderFrontRegardless` 一下再被 orderOut。视觉上可能有一瞬的闪烁。解决：`AppDelegate.applicationDidFinishLaunching` 里在创建 controller 的 `setup()` **之前** 就把 visibility 通过初始化参数注入 controller，让 `createPanel()` 末尾按 visibility 决定是 `orderOut` 还是 `orderFrontRegardless`。实现时需要注意这一点
- **welcome onboarding + hidden 的初次体验**：首次启动的 welcome 会强制弹出 3 秒，即使用户在 0.2.x 就已经设 hidden（理论不可能，但升级路径上要考虑）。welcome 逻辑不变，事件优先原则下这是正确行为

## 实现清单（供写实现计划时参考）

- [ ] `Sources/AppLib/Config/NotchVisibility.swift`（新建）
- [ ] `Sources/AppLib/Config/ConfigStore.swift`：加字段 + 读写方法
- [ ] `Sources/AppLib/MenuBar/StatusBarMenu.swift`：加菜单项 + action
- [ ] `Sources/AppLib/MenuBar/MenuBarFallback.swift`：图标 `sparkles` → `star.fill`
- [ ] `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift`：visibility 字段 + `applyVisibility` + hover 守卫 + compact 末尾 orderOut + forceExpand 前 orderFront
- [ ] `Sources/AppLib/Notch/NotchWindowController.swift`：同上（对应真刘海 API）
- [ ] `Sources/ZackEyes/AppDelegate.swift`：启动读 + 通知观察者 + controller 初始化顺序
- [ ] `Sources/AppLib/` 某合适文件：`Notification.Name.notchVisibilityChanged`
- [ ] `Tests/AppLibTests/ConfigStoreTests.swift`（或对应测试文件）：3 个新测试
- [ ] 手动验证 9 条全过
