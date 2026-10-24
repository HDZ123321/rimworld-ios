# build 5 — 世界生成崩溃 + DLC 资源修复

真机日志 `port-20261024-181342.log`（build 12，iPhone18,2 / iOS 27.2）里点「生成世界」直接回主菜单，日志给出三个根因，全部已修。

## 1. Burst 直调桩的静态构造函数在 IL2CPP 下必抛异常

```
System.TypeInitializationException: The type initializer for
'RimWorld.Planet.PlanetLayer.CalculateAverageTileSize_00015441_0024BurstDirectCall'
threw an exception. ---> System.ArgumentNullException: Value cannot be null.
Parameter name: burstMethodHandle
  at Unity.Burst.BurstCompiler.CompileILPPMethod2 (System.RuntimeMethodHandle)
  at RimWorld.Planet.PlanetLayer+CalculateAverageTileSize_00015441_0024BurstDirectCall..cctor ()
  at RimWorld.Planet.PlanetLayer.InitializeLayer ()
  at RimWorld.Planet.WorldGrid.RegisterPlanetLayer (...)
  at RimWorld.Planet.WorldGrid.CreateRequiredLayers ()
  at RimWorld.Planet.WorldGenerator.GenerateWorld (...)
```

每个 `*_0024BurstDirectCall` 都长这样：

```csharp
static Xxx_0024BurstDirectCall() { Constructor(); }
public static void Constructor() { DeferredCompilation = BurstCompiler.CompileILPPMethod2(default(RuntimeMethodHandle)); }
```

IL2CPP 下 `default(RuntimeMethodHandle)` 是零值，`CompileILPPMethod2` 立刻抛。
异常发生在**静态构造函数**里 → 类型永久变成 `TypeInitializationException` → 所有引用它的方法都炸。
`Invoke` 早就改成直接调 `*BurstManaged`（不走函数指针），`Pointer` 从不被读，所以编译这一步完全可以跳过。

修法：`Constructor()` 开头加 `if (PortPlatform.IsIOS) { return; }`。共 6 处：

| 文件 | 位置 |
| --- | --- |
| `src/RimWorld/MapGenUtility.cs` | `ComputeLargestRects_0000B773` / `RectsComputeSpaces_0000B774` |
| `src/RimWorld.Planet/FastTileFinder.cs` | `SphericalDistance_00014F7E` |
| `src/RimWorld.Planet/PlanetLayer.cs` | `CalculateAverageTileSize_00015441` / `IntGetTileSize_00015443` / `IntGetTileCenter_00015446` |

脚本：`work/port/build/fix_burst_cctor.py` + `fix_burst_cctor2.py`（后者用正则匹配该行实际缩进，因为三个文件的缩进是 2 tab / 3 tab 两种）。

## 2. 5 个 DLC 的 AssetBundle 是 Windows 版

```
The file can not be loaded because it was created for another build target that is not
compatible with this platform. ... File's Build target is: 19
```

19 = `StandaloneWindows64`，iOS 是 9。`AssetBundle.LoadFromFile` 直接拒载，后果：

| 错误 | 次数 |
| --- | --- |
| `Could not load Texture2D at 'World/WorldObjects/Expanding/YttakinPirates'` | 1113 |
| `... SavageImpidTribe` / `RoughPigUnion` / `FierceNeanderthalTribe` | 各 1113 |
| `... WasterPirates` / `TradersGuild` | 各 1112 |
| `MatFrom with null sourceTex.` | 1080 |
| `Material 'Custom/Cutout_BadTexture' ...` | 810 |
| `Terrain/Surfaces/PollutionFloorSmooth` | 312 |
| `Grain couldn't resolve: Clip not found at Ambience/RitualSustainers/...` | 10 |

### 修法：把 bundle 拆成散装文件

`ContentFinder<T>.Get(itemPath)` 的查找顺序是

1. `runningMods[i].GetContentHolder<T>().Get(itemPath)` ← **散装文件走这里**
2. `Resources.Load`
3. `TryFindAssetInModBundles(itemPath)` ← bundle 走这里

所以只要把 DLC 内容摊成 `StreamingAssets/Data/<Dlc>/Textures|Sounds/` 下的散装文件，第 1 步就命中，bundle 完全不需要。Mod 本来就是这么加载的。

工具：`work/tools/extract_dlc_bundles.py`

1. 起 `AssetRipper.GUI.Free.exe --headless --port 47901`
2. 对每个 DLC：`POST /Reset` → `POST /LoadFile {path: <bundle>}` → `POST /Export/PrimaryContent {path: <out>}`
3. 读 bundle 的 `.manifest`（里面是**打包时的原始大小写**，如 `Assets/Data/Royalty/Textures/Things/Pawn/.../CataphractArmor_Fat_north.psd`），把 AssetRipper 导出的**全小写**路径还原回原始大小写
4. 拷进 `StreamingAssets/Data/<Dlc>/<Textures|Sounds>/...`
5. 删掉原 `AssetBundles/` 目录，不再随包

关键坑：manifest 里是 `.psd` / `.wav`，AssetRipper 导出的是 `.png` / `.ogg`，**扩展名不同**，所以索引必须按「去扩展名的路径」建，否则 90% 的文件匹配不上（第一次跑只有 4225/13284 命中，改成按去扩展名索引后 9059 个文件全部命中、零遗漏）。

结果：

| DLC | 文件数 | 体积 |
| --- | --- | --- |
| Royalty | 670 | 42.1 MB |
| Ideology | 1491 | 40.5 MB |
| Biotech | 2136 | 78.2 MB |
| Anomaly | 2200 | 88.5 MB |
| Odyssey | 2562 | 117.5 MB |
| **合计** | **9059** | **366.8 MB** |

`StreamingAssets/Data` 从 491 MB 变成 633 MB（散装 png 比 LZ4 压缩的 bundle 大），但换来了跨平台可用。

### 验证

拿真机日志里出现过的每一个路径，去 staged 的散装文件里找：

- 贴图：**788 个唯一路径，788 命中，0 缺失**
- 音效：**253 个唯一路径，253 命中，0 缺失**

## 3. 开放泛型的 StaticConstructorOnStartup

```
Error in static constructor of RimWorld.PawnRoleSelectionWidgetBase`1[RoleType]:
System.TypeInitializationException ... ---> System.ExecutionEngineException:
Attempting to call method 'RimWorld.PawnRoleSelectionWidgetBase`1::.cctor'
for which no ahead of time (AOT) code was generated.
```

`StaticConstructorOnStartupUtility.CallAll()` 遍历 `GenTypes.AllTypesWithAttribute<StaticConstructorOnStartup>()`，里面包含开放泛型定义 `X<T>`。`RuntimeHelpers.RunClassConstructor` 对开放泛型没有意义，IL2CPP 也不会为它生成 `.cctor`。Mono 下这个调用同样无效但被静默忽略，所以原版没暴露。

修法：`CallAll()` 里 `if (item.IsGenericTypeDefinition || item.ContainsGenericParameters) { continue; }`。真正实例化成闭合泛型时 IL2CPP 会为那个具体类型生成 `.cctor`，语义不丢。

## 构建结果

```
result       : Succeeded
totalSize    : 2708.3 MB
totalErrors  : 0
[PortPostBuild] DONE
[PortBuild] Xcode project: .../Builds/iOS/Unity-iPhone.xcodeproj -> OK
```

产物核验：

- `Data/Raw` = **630 MB**（原 491 MB），六目录：Core 118M / Royalty 65M / Ideology 79M / Biotech 108M / Anomaly 118M / Odyssey 145M
- `Data/Raw/Data/**/Textures/**` 共 **5326** 个文件
- `find Data/Raw -name "resources_*"` → **0 个**（Windows bundle 已彻底移除）
- IL2CPP 生成代码里 `CompileILPPMethod2` 出现 11 个文件、`IsGenericTypeDefinition` 7 个文件 → 两处守卫都进了编译产物
- `PortPlatform_get_IsIOS_m26263AE821FB7A792A9B484358600DCE7CCF7912` 在 `Assembly-CSharp_CodeGen.c:16236` 有 extern 声明、`Assembly-CSharp__149.cpp:10734` 有定义

## 内存注意

散装贴图在 `PlayDataLoader` 阶段会被 `ModContentHolder<Texture2D>.ReloadAll()` 全部读进内存（bundle 是懒加载）。iPhone18,2 有 11695 MB 内存，5326 张 png 压力不大，但如果真机出现 OOM 或加载变慢，第一个要查的就是这里。
