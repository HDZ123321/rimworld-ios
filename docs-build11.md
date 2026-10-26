# build 11

打包日期 2026-10-26。这一版同时带上 build 10 从未出过包的三项修复，并新增两项：
关掉移动端静态图集（修掉主菜单烘焙闪退）、三层横屏锁（修掉默认竖屏与旋转错乱）。

## 0. 先说一件事：真机上跑的一直是 build 9

`git log` 里 build 10 停在 `38e31d4`，但 `origin/main` 是 `ce0f722`（build 9）。
build 10 的 payload 早已重打、只差一次 push，CI 从来没构建过它。
所以 `D:\下载\port-20261026-204347.log` 里那三个问题全部是 build 9 的表现——
其中地形马赛克、物件透明、27 秒等待，build 10 已经改完了，这次一并出包。

## 1. 图集烘焙闪退

### 崩溃点

日志最后一行：

```
12:44:14.445 +27s [STEP] [t1] Atlas.Bake calc done, blit begin size=4096x2048 cpuPath=True
```

group=`Building_False`，textures=176。前三张图集都烘焙成功（两张 4096x2048、一张
2048x2048，各耗时 34~78ms），第四张一进 blit 就没了——日志里没有任何 `[ERROR]`、
没有任何 `Exception`，进程是被系统直接收走的（jetsam / 显存分配失败），
所以托管层一行日志都来不及打。

### 为什么尺寸是 4096x2048

`StaticTextureAtlas.MaxPixelsPerAtlas` 在移动端返回 `2048 * 2048 = 4,194,304`，
这只是**切批预算**，不是图集边长。真实边长由 `CalcRectsForAtlasNew` 决定：

```csharp
a = Mathf.NextPowerOfTwo((int)((float)Mathf.CeilToInt(Mathf.Sqrt(num)) * 1.05f));
```

`num` 顶到 4,194,304 时 `sqrt = 2048`，乘 1.05 得 2150，`NextPowerOfTwo` 直接
跳到 **4096**。然后 `num2 = NextPowerOfTwo(ceil(num / a)) = 1024`，排版溢出后
走 `useIncreasedShortAxis` 把 `num2` 再乘 2 → **4096x2048 = 8,388,608 px**，
正好是预算的两倍。一张 RGBA32 + 4 级 mip 约 44MB，加上同尺寸 RenderTexture 和
`ReadPixels` 的 CPU 副本，单张瞬时 ~120MB；四张叠在内存里（此时 11,558 张贴图
全部常驻，卸载发生在烘焙之后），12GB 机型也会被掐。

### 修法

移动端不再生成静态图集：

```csharp
public static bool EnableStaticAtlas = !PortPlatform.IsMobile;
```

- `BakeStaticAtlases()` 直接返回，打一行 `Atlas.BakeStaticAtlases skipped (static atlas disabled on mobile)`。
- `TryInsertStatic` 直接 return false，贴图不往静态图集里塞，`Graphic` 回落到
  逐张 `Material` 渲染。

RimWorld 的静态图集是桌面端为省 draw call 做的批合并，移动端本来就把
`MaxPixelsPerAtlas` 砍到桌面的一半，再叠上 IL2CPP 的 CPU 端 `ReadPixels` 光栅化
路径（`UnityData.ComputeShadersSupported` 在 iOS 恒为 false，走 `cpuPath=True`），
等于拿几十 MB 显存换几十个 draw call。手机上这笔买卖不划算，直接关掉最稳。

## 2. 默认竖屏 + 旋转错乱

日志 ENV 行 `screen=1290x2796`、OnGUI `737x1598`——iPhone 竖着拿就竖屏起，
而 RimWorld 的 IMGUI 只有横屏布局，于是所有窗口错位；转一次屏又触发一次
`Screen` 尺寸重算，UI 缓存的 `UIRoot` 尺寸和实际视口对不上。

三层同时锁死：

| 层 | 位置 | 改动 |
| --- | --- | --- |
| 构建期 ProjectSettings | `Assets/Editor/PortBuild.cs:168` | `allowedAutorotateToPortrait = false`（原来 true） |
| 产物 Info.plist | `Assets/Editor/PortPostBuild.cs` | 新增 `UISupportedInterfaceOrientations` / `~ipad`，只留 LandscapeLeft / LandscapeRight |
| 运行期 | `Verse/PortPlatform.ApplyScreenOrientation()` | `Screen.orientation = LandscapeLeft` + 关掉 portrait 自动旋转，由 `Root.CheckGlobalInit` 在任何界面构建之前调用 |

生成结果（`Builds/iOS/Info.plist`）：

```xml
<key>UISupportedInterfaceOrientations</key>
<array>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>
```

iPad 那份 `~ipad` 同样只有两条横屏。启动后日志会多一行
`PortPlatform: orientation locked to landscape, screen=2796x1290 safeArea=...`，
`screen` 是横的就说明这一层生效了。

## 3. 随包带上的 build 10 修复

1. **地形马赛克**：`SectionLayer_Terrain` 建网格时从不写 `uvs`，`LayerSubMesh.FinalizeMesh`
   因为 `uvs.Count == 0` 跳过 `SetUVs(0, ...)` → 网格无 UV0 → 片元着色器采
   `input.uv` 恒为 (0,0) → 整片地形一个颜色。build 10 重新生成了 193 个 shader，
   地形类改用世界坐标：
   `output.uv = float2(mul(unity_ObjectToWorld, input.pos).xz)`，幕布类用
   `float2(worldPos.x + worldPos.z, worldPos.y)`。
2. **物件不显示**：v1 的 frag 是 `_MainTex.Sample(...) * input.color * _Color`，
   `_Color.a` 混进 alpha；`SkyManager` 给 `MatBases.LightOverlay` 写 `_Color.a = 0`
   把整层打成全透明，cutout 的 `clip(c.a - 0.5)` 又把树全 discard。v2 拆成
   `rgb = t.rgb * input.color.rgb * _Color.rgb`、`a = t.a * input.color.a`，
   cutout 只看 `t.a`。
3. **27 秒等待**：音效目录 `SubSoundDef.ResolveReferences` 把推迟的 clip 全解码了，
   占了 7.6 秒黑洞。build 10 改成 ResolvedGrain 只留路径、首次播放才解码。

## 4. 本机产出的验证

- Unity 2022.3.35f1 batchmode `PortBuild.BuildIOS` → `result: Succeeded`
- `Il2CppOutputProject/Source/il2cppOutput` 796 个文件，`ApplyScreenOrientation`
  出现在 `Assembly-CSharp__43.cpp`，`EnableStaticAtlas` 在 `Assembly-CSharp__42.cpp`
  的 `BakeStaticAtlases` 前做了分支——build 11 的代码确实进了包。
- payload 重打后 7 卷 / 639.8 MB。

## 5. 真机要看的三行

```
PortPlatform: orientation locked to landscape, screen=2796x1290 ...
CellRendererMap / SectionLayer_Terrain 之后不再出现大片同色
Atlas.BakeStaticAtlases skipped (static atlas disabled on mobile)
```

第三行出现、且后面没有 `Atlas.Bake` 开始，就说明闪退的那条路径整段不跑了。
