# build 6 — 修 build 15 的诊断缺陷

build 15 的价值全在「游戏自报状态」，但自查发现诊断本身有 5 个缺陷，最要命的两个让**红块和黄块永远画不出来**——而那恰好是最可能的状态。

## 缺陷与修法

### 1. 红块 / 黄块不可达（致命）
`Verse/Root.cs` `OnGUI()` 原来的顺序是：

```
portOnGuiFrames++
埋点
LongEventHandler.LongEventsOnGUI()
if (LongEventHandler.ShouldWaitForEvent) { ScreenFader.OverlayOnGUI(...); return; }   // ← 黄块条件就是这个，但这里早退
PortEvent.BeginInject()
DrawUIRoot()      // ← 第一行 uiRoot.UIRootOnGUI()，uiRoot 为 null 时抛 NRE
PortDiagBox()     // ← 红块条件就是这个，但上面抛了就跳去 catch
catch { Log.Error(...) }
```

修法：
- `PortDiagBox()` 提前到 `portOnGuiFrames++` 之后、`LongEventsOnGUI()` 之前 —— 早退之前就能画。
- `DrawUIRoot()` 开头给 `uiRoot` 加 null 守卫。
- `DrawUIRoot()` 之后再画一次，保证绿/蓝态不被菜单背景盖住。
- 色块从 1 个角落改成 3 个（左上 / 左下 / 右下），右对齐的菜单不会遮挡。

### 2. 蓝块会误报
`PortLastShouldDoMainMenu` 原来是 `bool`，初值 `false`。`DoMainMenu()` 一次都没跑到时，蓝块会误报「dialog blocks」。
改成 `int`：`-1` = DoMainMenu 从未运行（新色：**品红**）、`0` = 被对话框挡住（蓝）、`1` = 正常（绿）。

### 3. `UIMenuBackgroundManager.background` 空引用
`DoMainMenu()` 里 `UIMenuBackgroundManager.background.BackgroundOnGUI();` 无 null 检查。`MainMenuDrawer.Init()` 若抛异常，`background` 可能未建。加 null 守卫 + 重建。

### 4. `MainMenuDrawer.Init()` 空集合崩溃
```csharp
BackgroundMain.overrideBGImage = ModLister.AllExpansions
    .Where(exp => exp.Status == ExpansionStatus.Active).RandomElement().BackgroundImage;
```
`RandomElement()` 在空集合上抛 `Sequence contains no elements`，被 `Root.Start()` 的 catch 吞成一行 `Critical error in root Start()`，主菜单静态字段全为 null → 空白界面。改成先 `ToList()` 判空再回落 Core 背景。

### 5. `Root.destroyed` 分支全黑
`OnGUI()` 第一行 `if (destroyed) return;` —— 一旦 Root 被标记销毁（`Update()` 里 `sceneChanged` 分支），界面永久黑屏且无任何日志。加 `PortDiagBoxDestroyed()`（紫色），在 return 之前画。

## 新增的一次性诊断转储

`PortDumpDiagOnce()` 在 `DrawUIRoot()` 第一次执行时打一行 `DIAG ...`，包含：

```
uiRoot / progState / scene / screen / uiScreen / uiScale / guiMatrix / font
windows=[类型/层, ...] / expansions / bgOverride
```

## 色块对照表（build 6）

| 颜色 | 位置 | 含义 |
|---|---|---|
| 绿 | 三角 | 菜单正常绘制，问题在别处（触摸/输入） |
| 蓝 | 三角 | 有 Dialog 层窗口挡住主菜单 |
| 品红 | 三角 | `DoMainMenu()` 从未运行 |
| 黄 | 三角 | 长事件还在等待 |
| 红 | 三角 | `uiRoot` 为 null（UIRoot 没建起来） |
| 橙 | 三角 | `OnGUI()` 抛异常（日志里有完整堆栈） |
| 紫 | 三角 | Root 已 destroyed，`OnGUI()` 走早退分支 |
| **无色块** | — | `OnGUI()` 根本没被 Unity 调用 |

## 构建

- 本地 Unity：`result: Succeeded` / `totalSize: 2708.6 MB` / `totalErrors: 0` / `error CS` = 0
- `global-metadata.dat` 里新字符串各 1 处：`DoMainMenu never ran`、`root destroyed`、`DrawUIRoot skipped`、`DIAG uiRoot=`、`RandomBackgroundImage: no active expansion`、`background is null`
- payload：7 卷 / 639.9 MB
