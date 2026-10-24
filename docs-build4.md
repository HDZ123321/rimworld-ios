# build 4 — 世界生成卡死修复 + 落盘日志

上一版（ipa-11）真机反馈：点「生成世界」之后界面停在加载条，永远进不去。

## 根因

`RimWorld/Page_CreateWorldParams.cs` 把整个 `WorldGenerator.GenerateWorld` 用
`LongEventHandler.QueueLongEvent(..., doAsynchronously: true, null)` 丢到后台 `Thread` 跑。

生成链路里有两处必须在 Unity 主线程执行：

- `World.FinalizeInit(fromLoad)` → `AmbientSoundManager.EnsureWorldAmbientSoundCreated()`
  → `SoundDefOf.Ambient_Space.TrySpawnSustainer(SoundInfo.OnCamera())`
  → `AudioSourcePoolCamera` 构造函数 `new GameObject(...)` × 17 + `AddComponent<AudioSource>()`
- `World.ConstructComponents()` 里 `new WorldRenderer() / new WorldInterface() / new WorldDrawLayer_*`，
  内部 `new Mesh()` / `new Material(...)`

Unity 对非主线程抛 `UnityException: ... can only be called from the main thread`。
这个异常被 `LongEventHandler.RunEventFromAnotherThread` 的 `catch` 吞成一条 `Log.Error`，
而 `exceptionHandler` 传的是 `null`，所以既不弹窗也不回主菜单 —— 表现就是永久卡住。

Windows 上原版没事，是因为桌面端这条路恰好没触发；iOS 的 IL2CPP + Metal 下必然触发。

## 修复

### 1. iOS 上禁用后台长事件（`Verse/LongEventHandler.cs`）

两个 `QueueLongEvent` 重载里：

```csharp
doAsynchronously = doAsynchronously && !PortPlatform.IsIOS,
```

iOS 上所有长事件统一走 `UpdateCurrentSynchronousEvent`，主线程执行，进度界面照常显示。
`ShouldWaitUntilDisplayed` 的时序依赖 `doAsynchronously == false`，所以进度条仍然先渲染一帧再跑。

### 2. 给世界生成补异常处理（`RimWorld/Page_CreateWorldParams.cs`）

```csharp
}, "GeneratingWorld", doAsynchronously: true, GameAndMapInitExceptionHandlers.ErrorWhileGeneratingMap);
```

原来第 4 个参数是 `null`。改成 `ErrorWhileGeneratingMap` 后，万一还有别的原因失败，
会弹「生成地图时发生错误」并回主菜单，而不是静默死掉。

### 3. 主线程守卫（`RimWorld/AmbientSoundManager.cs`）

`EnsureWorldAmbientSoundCreated()` 开头：

```csharp
if (!UnityData.IsInMainThread)
{
    PortLog.Warn("EnsureWorldAmbientSoundCreated skipped: not on main thread");
    return;
}
```

环境音是可选效果，非主线程时直接跳过，不抛异常。双保险。

## 新增：落盘日志 `Verse/PortLog.cs`

原版 `Verse.Log` 只在内存里排队，靠 `EditWindow_Log` 展示，游戏卡死/崩溃后什么都不剩。
iOS 上拿不到编辑器控制台，所以新加一个静态日志类：

- 位置：`Application.persistentDataPath/SaveData/Logs/port-yyyyMMdd-HHmmss.log`
  （iOS 上 `persistentDataPath` 就是 `<App>/Documents`，所以开了文件共享后能直接从「文件」App 取）
- 挂 `Application.logMessageReceivedThreaded`，把 Unity 全部日志（含异常堆栈）落盘
- 挂 `AppDomain.UnhandledException` / `TaskScheduler.UnobservedTaskException`
- 单文件上限 8 MB，超了写一行截断标记后停止写入，不会写爆沙盒
- 行格式：`HH:mm:ss.fff +NNNs [LEVEL] [t<线程号>] message`
- 启动时写一段环境信息（设备型号、iOS 版本、Unity 版本、屏幕/DPI/安全区、路径）

### 埋点位置

| 位置 | 内容 |
| --- | --- |
| `Verse/Root.cs` `CheckGlobalInit` | `PortLog.Init()` + `Root.CheckGlobalInit done` |
| `Verse/LongEventHandler.cs` 同步事件 | `LongEvent START/DONE/FAILED textKey=... levelToLoad=...`（含耗时 ms） |
| `Verse/LongEventHandler.cs` 后置事件 | `ExecuteToExecuteWhenFinished begin count=N`、`PostLongEvent FAILED` |
| `RimWorld.Planet/WorldGenerator.cs` | 每个 `GameSetupStep` / `WorldGenStep` 的 begin/done，以及 `FinalizeInit` / `PostWorldGenerate` |
| `RimWorld/Page_CreateWorldParams.cs` | `WorldGen begin seed=... coverage=...` / `WorldGen GenerateWorld returned` |

卡在哪一步，日志最后一行就是答案。

## 新增：`Assets/Editor/PortPostBuild.cs`

`[PostProcessBuild(1000)]` 在 Unity 导出 Xcode 工程后改 `Info.plist`：

| 键 | 值 | 作用 |
| --- | --- | --- |
| `UIFileSharingEnabled` | true | Documents 出现在「文件」App「我的 iPhone」下 |
| `LSSupportsOpeningDocumentsInPlace` | true | 「文件」App 就地打开，不复制 |
| `UIApplicationSupportsIndirectInputEvents` | true | iOS 13+ 触控板/鼠标走 UIPointer |
| `UIViewControllerBasedStatusBarAppearance` | false | 保持全屏隐藏状态栏 |
| `ITSAppUsesNonExemptEncryption` | false | 免掉每次上传的出口合规问询 |

写的是原始 XML，不依赖 UnityEditor.iOS.Xcode 的 PlistDocument，避免版本差异。

## 取日志的方法

1. 玩到出问题，退出游戏（或直接杀进程）
2. 打开 iOS「文件」App → 「我的 iPhone」→「RimWorld by Ludeon Studios」→ `SaveData/Logs/`
3. 最新的 `port-*.log` 就是本次运行记录

存档也在这个 App 目录下：`SaveData/Saves/`。

## 其它顺手确认

- `-BurstDirectCallInitializer.cs` 里 6 个 `Initialize()` 是空方法体；
  `*_0024BurstDirectCall.Invoke(...)` 已全部改成直接调 `*_0024BurstManaged(...)`，
  所以 `BurstCompiler.GetILPPMethodFunctionPointer2` 从不会被调用，IL2CPP 下安全。
- 5 个 DLC 内容、字体、语言包均与 build 11 一致，未改动。
