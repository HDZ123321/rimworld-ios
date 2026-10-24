# build 5 — 主菜单不渲染的诊断版

## 真机现象（build 14 / ipa-14）
`port-20261025-004114.log` 显示加载链路**全部通过**：
- `ExecuteToExecuteWhenFinished done in 27983ms count=9469`
- `LongEvent action DONE in 34ms textKey=InitializingInterface`

之后一行日志都没有：无异常、无 `PostLongEvent FAILED`、无 `WATCHDOG main thread stuck`。
屏幕停在黑屏/空白，进不去主菜单。

## 本轮加的东西
1. `Verse/Root.cs` — `uiRoot` 创建加 `else` 兜底：场景名既不是 `Entry` 也不是 `Play` 时回落 `new UIRoot_Entry()` 并打警告（原版会留 null，之后每帧 NRE）。
2. `Verse/Root.cs` — `Update()` / `OnGUI()` / `DrawUIRoot()` 前 3 帧 + 每 300 帧打心跳：`uiRoot` 类型、`destroyed`、`shouldWait`、`progState`、`screen`、`uiScale`。
3. `Verse/UIRoot_Entry.cs` — `DoMainMenu()` 打 `worldSelected / shouldDoMainMenu / windows / bg / progState`。
4. `RimWorld/MainMenuDrawer.cs` — `MainMenuOnGUI()` 进/出各打一次。
5. `Verse/UI.cs` — `ApplyUIScale()` 发现 `Prefs.UIScale <= 0.01` 时强制回 1.0 并告警。
6. **屏幕左上角 18×18 诊断色块**（`Root.PortDiagBox()`）：
   - 红 = `uiRoot == null`（没建 UIRoot）
   - 黄 = `LongEventHandler.ShouldWaitForEvent`（卡在长事件）
   - 蓝 = `!UIRoot_Entry.PortLastShouldDoMainMenu`（有对话框挡住主菜单）
   - 绿 = 正常绘制主菜单
   - **色块完全不出现 = OnGUI 根本没被 Unity 调用**

## 怎么读结果
- 有绿块但仍看不到菜单 → 菜单画在屏幕外或 `GUI.matrix` 缩放异常，看 `MainMenuOnGUI` 心跳里的 `screen` / `uiScale`。
- 有蓝块 → 抓 `DoMainMenu` 心跳里的 `windows=` 列表，是某个 Dialog 挡住了。
- 有黄块 → 长事件没结束，抓 `WATCHDOG` / `LongEvent` 行。
- 有红块 → 场景名不对，日志里会有 `Scene name is neither Entry nor Play: '...'`。
- 无色块 → 渲染管线层面没跑 OnGUI，下一步查 `Camera` / `EventSystem` / `MonoBehaviour` 是否被禁用。
