# build 12（草案）— iOS 手机 / 平板适配

打包日期待定。这一版不加内容，只做移动端可用性与稳定性：触控判定、切后台不丢档、
按内存分画质、UI 缩放在刘海/小白条下不复位、以及构建期两条 iOS 系统手势设置。

## 0. 先说清楚：这批改动必须本机重跑 Unity 才会进 ipa

CI（`build-ios.yml`）只做 xcodebuild，**不编译 C#**。payload 里的
`Assembly-CSharp.dll` 是 IL2CPP 产物，来自本机 Unity 导出 `Builds/iOS` 时生成的
`Il2CppOutputProject`。所以：

| 改动类型 | 生效方式 |
| --- | --- |
| `Assets/Scripts/**/*.cs`（运行期逻辑） | 本机 `PortBuild.BuildIOS` → 重打 payload → push → CI 出包 |
| `Assets/Editor/PortBuild.cs`（构建设置） | 同上，写进 `ProjectSettings` 与 `Info.plist` |
| `.github/workflows/*`、`payload/*` | 直接 push |

只 push 源码不会改变 ipa 的任何行为。

## 1. 触控阈值按 DPI 归一（`Verse/PortInput.cs`）

旧参数是写死的像素：轻点容差 24px、双指判定 8px、双指轻点 250ms。

- 24px 在 3x 屏（iPhone，约 460dpi）上只有 8pt，手指按下那一下的微抖动就超过阈值，
  **长按被判成拖动，右键菜单弹不出来**。
- 2x 的 iPad 上 24px 又偏紧，双指轻点经常超时变成双指拖动。

现在统一按 dp（1dp = 1/160 英寸）换算，`RefreshTouchMetrics()` 每帧核一次 `Screen.dpi`，
变了才重算（外接屏 / 编辑器改分辨率都不会漏）：

```csharp
private const float TapTravelDip = 12f;        // 轻点容差
private const float TwoFingerPanDip = 8f;      // 双指拖动判定
private const float MinTapTravelPx = 24f;      // 下限，dpi=160 时的退路
private const float TapMaxSeconds = 0.35f;     // 双指轻点窗口 0.25 → 0.35
```

`Screen.dpi` 返回 0 的设备按 160dpi 处理，等价于退回旧的像素值——不会因为取不到 dpi
把阈值算成 0。

## 2. 切后台暂停 + 自动存档（`Verse/Root.cs`）

新增 `Root.OnApplicationPause(bool)`。三条硬需求，缺一条都会掉档：

1. **停 tick**。RimWorld 是单线程 tick 游戏，Unity 在 pause 时只停渲染，`Update` 在被系统
   挂起前还会继续跑，回来时后台已经过了几十秒到几分钟——玩家一走神回来发现自己被袭击、
   饿死、着火。
2. **立刻存盘**。iOS 内存紧张时直接 SIGKILL，而 RimWorld 的 autosave 默认 3 天一次游戏内
   时间，真机实测切两次 App 丢一次进度。
3. **交还熄屏策略**，否则驻留后台还占着 `NeverSleep`。

回来时不自动恢复 tick，保持暂停等玩家自己点继续；屏幕策略重新接管。

日志会打 `OnApplicationPause: tick paused` / `OnApplicationPause: autosaved` /
`OnApplicationResume: display policy restored, tick stays paused`。

## 3. 画质按内存分档（`Verse/PortPlatform.ApplyQualityTier()`）

构建期把 `QualitySettings` 全刷成「无 AA」是为了 CI 可复现，但运行时还得按机器分档。
RimWorld 的实时阴影只有太阳投影一张，关掉不损失观感，省的是老机型的填充率：

| tier | 内存 | fps | 阴影 | mipmap |
| --- | --- | --- | --- | --- |
| 0 | ≤2GB（iPhone SE / iPad 6） | 30 | 关（shadowDistance=0） | 限 1 级 |
| 1 | 3~4GB（iPhone XR / iPad 9） | 60 | 硬阴影（25） | 限 1 级 |
| 2 | ≥6GB（iPhone 13+ / iPad Pro） | 60 | 硬阴影（25） | 全分辨率 |

`globalTextureMipmapLimit` 只降世界贴图，IMGUI 图标走 0 级不受影响。
`Root.CheckGlobalInit` 里与 `ApplyDisplayPolicy()` 一起调用，任何界面构建之前。

## 4. UI 缩放在安全区里复核（`RimWorld/ResolutionUtility.cs`）

iOS 上原来完全不校验 `Prefs.UIScale`：只要 `Prefs.xml` 是从别的设备 / 备份带过来的
（`uiScale=2` 配 iPhone 的逻辑宽），窗口会**永久顶出屏幕，重启也修不回来**。

- `UIScaleSafeWithResolution` 的 iOS 分支改走 `PortPlatform.UIScaleFits(scale)`——
  iOS 改不了分辨率，`w/h` 传进来永远是当前物理屏，而且刘海 / 小白条吃掉一圈，
  判据统一换成「安全区里还剩多少逻辑空间」。
- `Update()` 里每 30 帧复核一次，放不下就拉回 `RecommendedUIScale` 并打
  `UIScale <x> does not fit safe area (...) , resetting to <y>`。

## 5. 构建期 iOS 设置（`Assets/Editor/PortBuild.cs`）

两项新增，都经过 UnityEditor 编译验证：

```csharp
PlayerSettings.iOS.hideHomeButton = true;
// 底边小白条自动隐藏：Unity 的 -[prefersHomeIndicatorAutoHidden] 直接返回
// UnityGetHideHomeButton()，所以这一项是它唯一的开关。

PlayerSettings.iOS.deferSystemGesturesMode =
    UnityEngine.iOS.SystemGestureDeferMode.LeftEdge |
    UnityEngine.iOS.SystemGestureDeferMode.RightEdge;
// 左/右边缘系统手势延迟到第二次滑动：横屏全屏游戏第一次边缘滑动先交给 App。
// RimWorld 的右侧菜单栏、左侧工作优先级都贴着屏幕边，默认会被系统手势吃掉。
```

`Preflight` 会多打两行确认：`HomeButton : True`、`DeferGestures : LeftEdge, RightEdge`。

## 6. 本地验证（不含真机）

- `work\tools\cc-check`（Assembly-CSharp 全量，带 `UNITY_IOS`）：0 error 0 warning
- `work\tools\cc-check-editor`（`Assets\Editor`，新增）：0 error 0 warning
  —— 这两个工程就是用来在本地确认 C# 没写错、Unity API 名/类型没错，别等 Unity
  batchmode 跑到 40 分钟才炸。

## 7. 重打包步骤

```powershell
# 1) 导出 Xcode 工程（含 il2cpp，约 30~50 分钟）
& 'D:\Unity\2022.3.35f1\Editor\Unity.exe' -batchmode -nographics -quit -accept-apiupdate `
  -projectPath 'D:\Documents\Deepseek\郝大章\rimworld_ios\work\unity_project\ExportedProject' `
  -executeMethod PortBuild.BuildIOS `
  -logFile 'D:\Documents\Deepseek\郝大章\rimworld_ios\work\unity_build12.log'

# 2) 确认 info
Select-String 'D:\Documents\Deepseek\郝大章\rimworld_ios\work\unity_build12.log' -Pattern 'HomeButton|DeferGestures|Build Summary|result'

# 3) 重打 payload 分卷（7z，脚本见 repo/scripts）
# 4) push → CI xcodebuild → 出 ipa
```

## 8. 真机要看的日志行

```
PortPlatform: orientation locked to landscape, screen=2796x1290 safeArea=...
PortPlatform: sleepTimeout=NeverSleep, deviceClass=..., uiScale=...
PortPlatform: quality tier=2 memMB=..., fps=60
OnApplicationPause: tick paused
OnApplicationPause: autosaved
OnApplicationResume: display policy restored, tick stays paused
```

`quality tier` 那行的 `fps` 与 `tier` 对得上，第 3 节那张表就算生效。
切一次 App 再回来，存档目录里应有 `*.rws` 时间戳更新。
