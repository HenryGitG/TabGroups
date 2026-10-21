# TabGroups：仿 TrellisWM 的跨 app 标签组（Swift 原型）

[English](README.md)

把一个窗口拖到另一个窗口的**中间**，停一下（约 0.35 秒）出现高亮，松手后两个窗口叠成一组，共用上方一条标签栏，不管它们属于哪个 app。
点标签切换；在栏内拖动标签可以排序；把标签拖出栏外就撕下来成为独立窗口；鼠标悬停时点 ✕ 关闭这个窗口；右键标签可以把它移出组，或解散所有组（Ungroup All）；右键菜单里还有「Launch at Login」开关，打勾后开机自动启动（只在以 `TabGroups.app` 运行时可用，`swift run` 时是灰的）。

## 运行

需要 macOS 14 及以上和 Xcode 15 及以上（Swift 5.9）。

```bash
# 方式 A：直接跑（权限会挂在 Terminal / iTerm 上）
swift run

# 方式 B：打包成 .app（推荐，权限挂在 TabGroups.app 上）
chmod +x make-app.sh && ./make-app.sh && open build/TabGroups.app
```

第一次运行会弹出辅助功能授权，请到「系统设置 ▸ 隐私与安全性 ▸ 辅助功能」里勾选它。授权后无需重启，程序每秒检查一次，拿到权限就会开始工作。
程序不能放进沙盒：Accessibility API 在沙盒里不可用，所以它也上不了 Mac App Store。

程序没有 Dock 图标也没有菜单栏图标。退出时（在终端按 Ctrl-C，或 `pkill -INT TabGroups`，或在活动监视器里点「退出」）会先解散所有组，把藏起来的窗口放回屏幕上。

## 文件

| 文件 | 作用 |
|---|---|
| `AX.swift` | Accessibility API 的封装、私有函数 `_AXUIElementGetWindow`、AX 坐标（左上原点）和 AppKit 坐标（左下原点）的互相转换 |
| `WindowTracker.swift` | 给每个 app 建一个 `AXObserver`，维护「CGWindowID → 窗口」表；用 `CGWindowListCopyWindowInfo` 按真实层级找出光标下面的窗口 |
| `DragController.swift` | 全局监听鼠标事件；判断是否在拖动标题栏、光标是否在目标中间区域、是否停留够久，然后显示高亮 |
| `GroupManager.swift` | 标签组模型：合并、切换、把不显示的标签「停放」到屏幕外、撕下、跟随移动、解散 |
| `TabStrip.swift` | 标签栏：一个不会抢焦点的 `NSPanel`，负责绘制、点击、拖动排序、撕下时跟随光标的小卡片 |

## 已知限制（原型阶段）

- 被停放的窗口还在屏幕角落露出 1 像素，在 Mission Control 里也会显示，退出 Mission Control 时能看到它飞回右下角。如果程序崩溃没来得及恢复，可以在那个 app 里用「窗口 ▸ 缩放」或 Mission Control 把它找回来。
- 最小化当前标签会让它离开所在的组；TrellisWM 的做法是通过标签栏把整组一起最小化。
- 还没有持久化，重启后组不会恢复。以后可以按 bundleID 加窗口标题保存，下次启动时再匹配回来。
- 对全屏窗口、原生标签窗口（Finder / Safari 的 `AXTabGroup`）、对话框和 sheet 没有专门处理。
- `order(.above, relativeTo:)` 用的是其他 app 的窗口编号。如果遇到某个 app 的标签栏被它的窗口盖住，可以在 `windowFocused` 里加一次延迟后再重新排一次层级。
