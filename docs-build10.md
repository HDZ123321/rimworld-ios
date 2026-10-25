# build 10 — 马赛克 / 物件不显示 / 27 秒等待

上一版（build 9）真机反馈：进地图后**地形是马赛克方块、地图上的东西（建筑、植物、物品）不显示、进游戏仍等 27 秒**，小人本身正常。

日志 `port-20261025-201317.log` 里三个根因都能定位，互不相关。

---

## 1. 地形马赛克 —— 地形网格从来没有 UV

`Verse/SectionLayer_Terrain.cs` 建地形网格的那段：

```csharp
subMesh.verts.Add(...);   // ×4
subMesh.colors.Add(...);  // ×4
// 没有 subMesh.uvs.Add
```

`Verse/LayerSubMesh.cs` 的 `FinalizeMesh`：

```csharp
if ((parts & MeshParts.UVs1) != MeshParts.None && uvs.Count > 0)
{
    mesh.SetUVs(0, uvs);
}
```

`uvs` 空表直接跳过，网格没有 UV0 → shader 里 `input.uv` 恒为 `(0, 0)` → 每一格都采贴图左上角同一个像素，整片地形变成同色方块（叠加 terrain 贴图本身的边缘色，看起来就是马赛克）。

原版 shader 不依赖网格 UV：它用**世界坐标**算贴图坐标。我们重写的 v1 shader 却用了 `input.uv`，所以露出来了。

**修法**：`gen_map_shaders.py` 改成按类别生成顶点阶段的 UV 来源（v2）：

| UV 来源 | 适用 | 代码 |
|---|---|---|
| `UV_MESH` | 其它所有类别 | `output.uv = input.uv.xy;` |
| `UV_WORLD_XZ` | 全部 `Custom/Terrain*` / `Custom/Snow` / `Custom/Sand` / `Custom/Water depth` / `Custom/TerrainEdge` | `output.uv = float2(worldPos.x, worldPos.z);` |
| `UV_WORLD_CURTAIN` | `Custom/TerrainCurtain`、`Custom/MapEdgeTerrain`（竖直面） | `output.uv = float2(worldPos.x + worldPos.z, worldPos.y);` |

`worldPos = mul(unity_ObjectToWorld, input.pos)`，不再使用 `_MainTex_ST`（网格 UV 已是最终坐标，世界坐标直接当 UV 用）。

---

## 2. 地图上东西不显示 —— alpha 被 `_Color.a` 掐死

v1 生成的 frag 统一是：

```hlsl
float4 c = _MainTex.Sample(sampler_MainTex, input.uv) * input.color * _Color;
return float4(c.rgb, c.a);
```

`_Color` 的 **alpha** 混进了输出 alpha。地图物件的材质是运行时 `new Material(shader)` 由 `Verse/Graphic` 创建 —— `_Color` 默认 `(1,1,1,1)` 时没事，但只要被写成 `a = 0`（`SkyManager` 给 `MatBases.LightOverlay` 就这么干），整层直接全透明。

cutout 更狠：

```hlsl
clip(c.a - 0.5);
```

`_Color.a = 0` → `c.a = 0` → 整棵树 `discard`，一棵都不剩。

**修法**：alpha 只取 **贴图 a × 顶点 a**，`_Color` 只当 RGB 染色。

```hlsl
// 有 _MainTex
float4 t = _MainTex.Sample(sampler_MainTex, input.uv);
float3 rgb = t.rgb * input.color.rgb * _Color.rgb;
float a = t.a * input.color.a;

// 无 _MainTex
float3 rgb = input.color.rgb * _Color.rgb;
float a = input.color.a;

// cutout 只看贴图 alpha
clip(t.a - 0.5);
return float4(rgb, 1.0);

// darkness 只看顶点 alpha（_ColorTwo.a 未必被设）
return float4(0, 0, 0, saturate(input.color.a));
```

---

## 3. 27 秒等待 —— 音效目录又把推迟的 clip 全解码了

build 9 已经把单 clip 的解码推迟到 `ResolvedGrain_Clip.GetClip()`，`ReloadAll<AudioClip>` 从 19,964ms 降到 150ms（各 mod 8/18/42/47/35ms），确实生效。

但总时间 `ExecuteToExecuteWhenFinished done in 27743ms` 一分没降。progress 采样给出答案：

```
 50/9469  elapsed=5589ms     ← ReloadContent，5.6 秒
7050/9469  elapsed=5893ms     ← 动作 50→7050 几乎免费
8050/9469  elapsed=14739ms    ← 动作 7000→8000 花 8.8 秒
9050/9469  elapsed=26764ms    ← 动作 8000→9000 花 12.0 秒
```

22 秒全在最后约 2400 个后置动作里，全是 `SubSoundDef.ResolveReferences`。

根因在 `Verse.Sound/AudioGrain_Folder.cs`：

```csharp
foreach (AudioClip clip in ContentFinder<AudioClip>.GetAllInFolder(clipFolderPath))
```

→ `ModContentHolder.GetAllUnderPath` 里 build 7 加的"先把该目录下推迟的 clip 全部补载"那段，一次把整个目录解码回来。`AudioGrain_Folder` 是"从一堆音里随机挑一个"，本来不需要全部解码。

**修法**：

- `Verse/ModContentHolder.cs` 删掉 `GetAllUnderPath` 里的强制补载，新增
  ```csharp
  public IEnumerable<string> PendingPathsUnder(string pathRoot)
  ```
  只返回还没解码的 path（排序后 yield，**不碰音频数据**）。
- `Verse/ContentFinder.cs` 新增
  ```csharp
  public static IEnumerable<string> GetAllInFolderLazyPaths(string folderPath)
  ```
  遍历各 mod 的 content holder 收集 `PendingPathsUnder`。
- `Verse.Sound/AudioGrain_Folder.cs` 的 `GetResolvedGrains()` 在 iOS 上追加：
  ```csharp
  if (PortPlatform.IsIOS)
  {
      foreach (string path in ContentFinder<AudioClip>.GetAllInFolderLazyPaths(clipFolderPath))
      {
          yield return new ResolvedGrain_Clip(path);
      }
  }
  ```
  每个候选仍是一条 `ResolvedGrain_Clip`（只存路径），真正播放时才解码。

---

## 4. 顺手加的诊断：`Verse/PortDiagnostics.cs`

进地图 5 秒后把中心 section 的每个 `SectionLayer` 全打一遍日志，出问题时不用再猜是没 UV、没贴图还是被 clip 掉。

```csharp
public static class PortDiagnostics
{
    public static void NotifyMapStarted();   // Root.Update 里每帧调，进地图后开始计数
    public static void Update();             // 满 300 帧 dump 一次
    private static void DumpMapRenderState(); // 遍历 map.mapDrawer.SectionAt(map.Center).PortLayers
}
```

每条 subMesh 输出：

```
mat=<材质名> shader=<shader名> tex=<贴图名 WxH fmt=..> _Color=RGBA(..)
verts=N tris=N uvs=N colors=N disabled=false meshVerts=N meshUV0=N meshCols=N
```

配套让 `Verse/Section.cs` 暴露 `public List<SectionLayer> PortLayers => layers;`（`layers` 原本是 private）。

日志位置不变：`文件 App / 我的 iPhone / RimWorld by Ludeon Studios / SaveData / Logs / port-*.log`。

---

## 已改文件清单

| 文件 | 改动 |
|---|---|
| `Assets/Resources/materials/**/*.shader` | 193 个全部重生成（v2），`world/` 18 个保持 build 7 版本 |
| `Verse/ModContentHolder.cs` | 删 `GetAllUnderPath` 强制补载；新增 `PendingPathsUnder` |
| `Verse/ContentFinder.cs` | 新增 `GetAllInFolderLazyPaths` |
| `Verse/Sound/AudioGrain_Folder.cs` | iOS 追加懒路径 grain |
| `Verse/Section.cs` | 新增 `PortLayers` 只读访问器 |
| `Verse/PortDiagnostics.cs` | **新增**，地图渲染状态 dump |
| `Verse/Root.cs` | `Update()` 里挂 `PortDiagnostics.Update()` / `NotifyMapStarted()` |

---

## 已知取舍

- `Custom/CutoutComplex`（小人身体 + 衣服合并）只采 `_MainTex`，`_OverlayTex` 的衣服配色会丢 —— build 8 起就是这样，用户反馈"小人没问题"，暂不动。
- stencil 遮罩层（Indoor mask / Roofed outdoor mask / Filled mask / Shadow mask）完全不画 → 雨、雾在室内也会渲染；纯视觉问题。
- 太阳阴影不做光照方向偏移，只是建筑脚下的一块暗影。
- `world/` 目录的 18 个 shader 仍是 build 7 手工版，其中 11 个是全新写的，另 7 个未验证。
