# build 4 (CI run) — 图集烘焙卡死修复

## 真机现象
build 13 日志停在：

```
14:25:55.168 +3s [STEP] [t1] ExecuteToExecuteWhenFinished begin count=9469
```

之后再无任何一行输出 —— 没有 `PostLongEvent progress`、没有 `SLOW`、没有 `FAILED`，
主线程永久阻塞在加载界面。

## 定位
`PlayDataLoader.LoadAllPlayData()` 用 3.48s 跑完，把 9469 个后置动作排队。
队列前 6 项来自 `ModContentPack.ReloadContent()`（每个 mod 一项），内部
`textures.ReloadAll()` **同步加载全部散装贴图**：

| 来源 | 贴图数 |
|---|---|
| Royalty | 1113 |
| Ideology | 2266 |
| Biotech | 2418 |
| Anomaly | 2158 |
| Odyssey | 3603 |
| **合计** | **11558** |

每张走 `LoadTextureViaImageConversion` → `LoadImage` → `Compress(highQuality: true)`。
11558 张串行，手机上是几十分钟级。

队列末尾还有 `GlobalTextureAtlasManager.BakeStaticAtlases()`，单张图集上限
`MaxPixelsPerAtlas = maxTextureSize/2 * maxTextureSize/2`，A19 Pro 上是
**8192×8192 = 6700 万像素**，`Compress(highQuality: true)` + mipmap 生成单张即分钟级。

## 修法（5 处）
1. `Verse/UnityData.cs` — `CopyUnityData()` 里移动端强制 `computeShadersSupported = false`。
   `EncodeBCn` 的 `EncodeBC3_AMD` kernel 是 AMD 专用 BCn 编码器，Metal 上
   `FindKernel` 可能返回 -1，`Dispatch(-1, ...)` 会永久阻塞；且
   `Graphics.CopyTexture` 从 `R32G32B32A32_SInt` 到 `RGBA_DXT5_UNorm` 格式不兼容。
2. `Verse/StaticTextureAtlas.cs` — `FastCompressDXT` 里 shader 为 null 或
   `kernelIndex < 0` 时直接返回原图，不再 Dispatch。
3. `Verse/StaticTextureAtlas.cs` — `MaxPixelsPerAtlas` 移动端降到 `2048*2048`
   （419 万像素，约 1/16）。图集数量变多，但单张烘焙时间线性下降。
4. `Verse/StaticTextureAtlas.cs` + `Verse/ModContentLoader.cs` — 移动端
   `Compress(highQuality: false)`。高质量压缩是 CPU 逐块算，速度差数倍，
   进图集后视觉差异不可见。
5. 埋点：`ModContentHolder.ReloadAll` 每 200 张打一次进度（含 mod 名、耗时、
   GC 占用、最后一张路径），单张 ≥200ms 单独告警；`StaticTextureAtlas.Bake`
   按 calc / blit / mask / meshes / compress 五段打点；
   `PlayDataLoader` 的静态构造、图集烘焙、GC 三段各打点。

## 预期效果
- 贴图加载从"几十分钟无输出"变成"每 200 张一行日志"，即使仍慢也能看到进度。
- 图集烘焙从分钟级降到秒级（尺寸 1/16 + 非高质量压缩）。
- 万一还有别的卡点，看门狗线程（15 秒无心跳即告警，打印 stage + action + gcMB）
  会直接指出卡在哪个后置动作。
