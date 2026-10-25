# build 7 — 世界地图全白 / 进游戏等待时间长 / 派系领袖生成失败

对应真机日志：`port-20261025-084530.log`（build 6，1758 行）。
用户反馈（原文）：

> 现在可以进入游戏，就是等待时间长，在生成世界的时选择着陆点的地图是全白色的。这是我遇见的两个问题

build 6 的诊断全部正常工作（`DiagBox state=dialog blocks`、每 300 帧一行心跳、`uiRoot=UIRoot_Entry`），
所以这一版不再加诊断，只修三个确定的问题。

---

## 1. 着陆点世界地图全白

### 根因

AssetRipper 从编译后的 shader 反推出来的 193 个 `.shader` 全部带 `//DummyShaderTextExporter` 标记，
其中 **15 个 shader 的片元着色器被还原成硬编码纯白**：

```hlsl
return float4(1.0, 1.0, 1.0, 1.0); // RGBA
```

世界地图上盖着两层**不透明球壳**，两个都命中这一条：

| 图层 | 材质 | 球壳半径 | 片元 |
|---|---|---|---|
| `WorldDrawLayer_Glow` | `WorldMaterials.PlanetGlow` | `Radius + 16.1` | 纯白、不透明、无 Fallback |
| `WorldDrawLayer_Clouds` | `WorldMaterials.Clouds` | `Radius + 0.2` | 纯白、不透明（`Tags{RenderType=Opaque}`） |

`PlanetLayers.xml` 的 `<worldDrawLayers>` 里 `Glow` 排第 11、`Clouds` 排最后，
`PlanetLayer.cs:487` 按顺序 `Activator.CreateInstance` 后 `WorldDrawLayers.Add` —— 后加的盖在上面。
所以整张地图被一个半径 +16.1 的白球包住，看起来就是全白。

**次因**：`worldterrain` / `worldocean` / `worldice` 的片元虽然保留了 `_MainTex.Sample(uv)`，
但 `WorldDrawLayer_Terrain.cs:76` 往 UV 通道 0 里塞的是 **elevation**：

```csharp
subMesh.uvs.Add(elevationValues[num]);   // Vector3(x=elevation, y=邻居最高elevation)
```

而 `WorldGenStep_Terrain.ElevationRange = new FloatRange(-500f, 5000f)`，Span 5500。
贴图是 512×512 且 `wrapU/wrapV = 0`（Clamp）→ 所有采样都被钳到贴图边缘一圈。

### 修法

重写 `Assets/Resources/materials/world/` 下 11 个 shader（原件备份到 `work/backup_shaders/`）：

| shader | 改动 |
|---|---|
| `worldterrain` / `worldice` / `worldocean` | `float2 uv = saturate(input.uv.xy / 5500.0 + 0.0909);` 把 elevation 归一化回 0..1 再采样 |
| `clouds` | 改 `Tags{RenderType=Transparent}` + `Blend SrcAlpha OneMinusSrcAlpha` + `ZWrite Off`，按世界坐标算球面 UV 采样 `_CloudTex`，alpha 乘 `_FinalOpacityMult` |
| `planetglow` | `Blend SrcAlpha One` + `ZWrite Off`，按 fresnel 画边缘光晕（`pow(fresnel, 3.0) * 0.25`） |
| `rivers` / `roads` / `worldvertexcolortransparent` | 输出顶点色 + `Blend SrcAlpha OneMinusSrcAlpha`，让 `WorldDrawLayer_Paths` 的 `MutateAlpha(0)` 渐变生效 |
| `worldvertexcolor` | 不透明版，直接输出顶点色 |
| `ungeneratedplanetparts` | 网格无 UV，固定采样贴图中心 |
| `sun` | 固定暖色 |

---

## 2. 进游戏等待时间长（约 30 秒）

### 实测构成

```
00:45:30.832  PortLog started
00:45:34.057  LongEvent action DONE in 3126ms      PlayDataLoader.LoadAllPlayData
00:45:34.057  ExecuteToExecuteWhenFinished begin count=9469
00:46:00.945  ExecuteToExecuteWhenFinished done in 26888ms
```

26.9 秒的后置动作里，**19.96 秒（74%）花在 3733 张 AudioClip 的同步解码上**：

| mod | AudioClip | 耗时 | Texture2D | 耗时 |
|---|---|---|---|---|
| Royalty | 148 | 3247ms | 522 | 362ms |
| Ideology | 477 | 1664ms | 1014 | 739ms |
| Biotech | 1014 | 3032ms | 1122 | 1344ms |
| Anomaly | 1209 | **7322ms** | 991 | 704ms |
| Odyssey | 885 | 4699ms | 1677 | 2103ms |

音效在进主菜单时绝大多数根本不会播放，没必要预解码。

### 修法：AudioClip 懒加载

`work/port/build/fix_lazy_audio.py`，8 处补丁：

- `Verse/ModContentLoader.cs` 的 `LoadItem`：iOS 上 AudioClip 分支只登记文件，返回 `contentItem = null`
- `Verse/ModContentHolder.cs`
  - 新增 `Dictionary<string, VirtualFile> pendingFiles`
  - `ReloadAll` 里 `contentItem == null && internalFile != null && typeof(T) == typeof(AudioClip)` → 进 `pendingFiles` + 进 `contentListTrie`
  - `Get(path)` 未命中时查 `pendingFiles`，命中就 `LoadPending(path, file)` 解一个并写回 `contentList`
  - `GetAllUnderPath(prefix)` 先批量补载该前缀下的 `pendingFiles`（否则 `AudioGrain_Folder` 随机取音会拿到空集合）
  - `ClearDestroy()` 清 `pendingFiles`
  - `ReloadAll` 结尾日志追加 `, deferred=N`

预期：进主菜单从 ~30 秒降到 ~10 秒。音效首次播放时多一次几毫秒的解码。

---

## 3. 派系领袖生成失败 → 99 条 `has null relation with PlayerColony`

### 原始异常

```
00:46:16.967 [ERROR] Error while generating pawn. Rethrowing.
System.ArgumentOutOfRangeException: Index was out of range.
  at System.Collections.Generic.List`1[T].get_Item (Int32 index)
  at RimWorld.IdeoStyleTracker.SetFrequency (StyleItemDef def, StyleItemFrequency freq)
  at RimWorld.IdeoStyleTracker.<RecalculateAvailableStyleItems>g__SetupFrequency|27_0[T] ()
  at RimWorld.IdeoStyleTracker.RecalculateAvailableStyleItems ()
  at RimWorld.IdeoStyleTracker.GetFrequency (StyleItemDef def)
  at RimWorld.PawnStyleItemChooser.WantsToUseStyle (...)
  at Verse.PawnGenerator.TryGenerateNewPawnInternal (...)
  at Verse.PawnGenerator.GeneratePawn (PawnGenerationRequest request)
  at RimWorld.Faction.TryGenerateNewLeader ()
  at RimWorld.FactionGenerator.NewGeneratedFaction (...)
  at RimWorld.FactionGenerator.GenerateFactionsIntoWorldLayer (...)
  at RimWorld.Planet.WorldGenerator.GeneratePlanetLayer (...)
```

### 根因

`Verse/DefMap.cs` 的索引器直接 `values[def.index]`：

- `values` 的长度在 `DefMap` 构造时按 `DefDatabase<D>.DefCount` 固定
- `Def.index` 默认值是 `ushort.MaxValue`（`Verse/Def.cs:42` `public ushort index = ushort.MaxValue;`），
  只有走过 `DefDatabase<T>.Add` / `SetIndices` 才会被赋成合法值
- `DefDatabase<T>.Remove()` 会 `SetIndices()` 重排全部 index

只要某个 def 的 index 落在 `values.Count` 之外（或还是 65535），就抛 `ArgumentOutOfRangeException`。
这条路径在 `Faction.TryGenerateNewLeader` 里被触发 → 每个派系的领袖都生成失败 →
派系关系表不完整 → 日志里 99 条 `Faction ... has null relation with PlayerColony. Returning dummy relation.`。

### 修法：让 DefMap 自愈

`work/port/build/fix_defmap.py`，4 处补丁：

- 索引器 `this[D def]` / `this[int index]` 读写前调 `EnsureCapacity(index)`，超出就按 `max(index+1, Count*2, 16)` 扩容填 `new V()`
- 构造函数容量取 `max(DefCount, 所有现有 def 的 index+1)`
- `ExposeData` 读档后**只扩容不裁剪**（原来 `while (values.Count > defCount) values.RemoveLast();` 会把仍被引用的尾部丢掉）

---

## 构建

```
Unity.exe -batchmode -nographics -quit \
  -projectPath <ExportedProject> \
  -executeMethod PortBuild.BuildIOS \
  -logFile D:/Unity/buildios8.log
```

```
result       : Succeeded
platform     : iOS
totalSize    : 2708.7 MB
totalErrors  : 2      (仅许可证联网噪声，error CS 计数 0)
```

## 已知仍然存在的问题

- 第一次进主菜单仍需等（贴图 5326 张 + 图集烘焙，实测约 6 秒；音效已改懒加载）
- 世界生成本身约 5 秒
- IMGUI `TextField` 在 iOS 上不唤起键盘（改名/存档名输不了字）
- `PortPlatform.SafeArea` 已实现但未接入 UI 布局
- 修饰键屏幕按钮未做，框选加选暂不可用
