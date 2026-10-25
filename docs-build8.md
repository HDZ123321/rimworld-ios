# build 8 — 重写全部 193 个 shader 的渲染状态

## 症状
build 7 能进游戏、世界生成成功、日志 0 条 ERROR，但进入地图后**地图和小人都是空白**。

## 根因
RimWorld 的地图不是一张图，是**几十个 SectionLayer 叠出来的**：

```
Terrain → TerrainEdges → Watergen → Snow/Sand → Things(小人/建筑)
        → LightingOverlay → EdgeShadows → SunShadows
        → IndoorMask / RoofedOutdoorMask / FilledMask / ShadowMask
        → Darkness → FogOfWar → 天气覆盖层
```

其中绝大多数是**半透明覆盖**或**纯 stencil 遮罩**。

AssetRipper 的 `DummyShaderTextExporter` 把构建里 193 个编译态 shader 反推成占位源码时，
**全部丢失了 Blend / ZWrite / Cull / alpha test / 顶点色**，统一变成：

```hlsl
Tags { "RenderType"="Opaque" }   // 不透明，队列 Geometry
// 没有 Blend，ZWrite 默认 On
```

于是每一个覆盖层都变成**实心色块**，按 y 高度叠上去，把地图和小人整个盖住。

最致命的一个：

| shader | 原 frag | 材质 _Color | 后果 |
|---|---|---|---|
| `Custom/Light overlay` | `return _Color;` | `(0.482, 0.603, 0.682, 0)` | **覆盖全屏的实心蓝灰矩形** |
| `Custom/Indoor mask` | `return float4(1,1,1,1);` | `(1,1,1,1)` | 屋顶/岩格变白块 |
| `Custom/Transparent` | 无 Blend + ZWrite On | — | 小人的头发/衣服/装饰互相遮挡 |

`Custom/Light overlay` 挂在 `AltitudeLayer.LightingOverlay`，比 `Things`（小人所在层）高，
所以它盖住一切 —— 这就是"空白"。

## 修法
`work/tools/gen_map_shaders.py` 按 shader 名重建渲染状态，13 类：

| 类别 | 数量 | Blend | ZWrite | Queue | 说明 |
|---|---|---|---|---|---|
| `lightoverlay` | 1 | `DstColor Zero` | Off | `Transparent+100` | 顶点色(glowGrid) 与 `_Color`(curSky.colors.sky) 取 max 后正片叠底 |
| `multiply` | 1 | `DstColor Zero` | Off | `Transparent+100` | Edge shadow，顶点色即明暗系数 |
| `sunshadow` | 2 | `DstColor Zero` | Off | `Transparent+60` | `lerp(1, _Color.rgb, 1-vertexAlpha)` |
| `darkness` | 1 | `SrcAlpha OneMinusSrcAlpha` | Off | `Transparent+200` | Anomaly 黑暗层 |
| `invisible` | 10 | `ColorMask 0` | Off | `Transparent` | 4 个 stencil 遮罩 + Gravship mask/chromakey + `Custom/Invisible` |
| `ground` | 16 | `SrcAlpha OneMinusSrcAlpha` | **On** | **`Geometry`** | 地形/雪/沙/水，必须早于实体画且写深度 |
| `cutout` | 15 | Off（alpha test 0.5） | **On** | `AlphaTest` | 小人身体/头发/衣服/植物 |
| `additive` | 30 | `SrcAlpha One` | Off | `Transparent` | 发光特效 |
| `alpha` | 100 | `SrcAlpha OneMinusSrcAlpha` | Off | `Transparent` | 其余覆盖层 |
| `world-kept` | 18 | — | — | — | build 7 已手工重写，跳过 |

两个关键的设计决定：

1. **地面必须走 `Geometry` 队列 + `ZWrite On`**。如果地面和普通半透明层一样放在
   `Transparent` 队列，Unity 会先画 `AlphaTest` 队列里的小人，再画地面 —— 地面反过来
   把小人盖住，症状和现在一模一样。
2. **所有 `frag` 都乘上顶点色**（`float4 color : COLOR`）。RimWorld 把光照、色调、
   渐变、切割全部烘进顶点色，原占位 shader 的顶点结构里连 `COLOR` 都没有。

## 构建
- `D:/Unity/buildios9.log`：`result: Succeeded` / `totalSize 2708.8 MB` / 无 shader 报错
  （`totalErrors: 2` 是 Unity 许可证联网噪声，`[Licensing::Client] Error: Code 10`）
- 549 次 shader 编译全部成功，无 `Shader error`
- payload 7 卷 639.9 MB（`.007` 73,248,656 B）

## 已知取舍
- `Custom/CutoutComplex`（小人身体+衣服合并 shader）只采样了 `_MainTex`，
  `_OverlayTex` 的衣服配色会丢 —— 小人可见但衣服可能是纯色底。后续可补。
- stencil 遮罩层改成完全不画，雨/雾在室内也会渲染（纯视觉，不影响玩法）。
- 太阳阴影不做光照方向偏移，只是建筑脚下的一块暗影。
