# RimWorld → iOS（自编译 ipa）

把 Windows 版 RimWorld 1.6（Steam 版）的 Unity 工程重建为 iOS 目标，用 GitHub Actions 的 macOS runner 编出**未签名 ipa**。签名由你自己完成（Sideloadly / AltStore / TrollStore / 自签证书皆可）。

## 仓库结构

```
payload/ios-build.7z.001 .. 007   Xcode 工程分卷（共 588 MB，每卷 95 MB）
.github/workflows/build-ios.yml   macOS CI：解包 → xcodebuild archive → 打 ipa
scripts/                          本地辅助脚本
```

`payload` 里是 `xcodebuild` 可直接消费的完整 Unity 导出工程：

- `Unity-iPhone.xcodeproj`（scheme `Unity-iPhone`，target `Unity-iPhone` → `UnityFramework` → `GameAssembly`）
- `Il2CppOutputProject/Source/il2cppOutput/` 1087 个 IL2CPP `.cpp`（1.3 GB）
- `Il2CppOutputProject/IL2CPP/build/deploy_arm64/` IL2CPP 主机工具链（Mach-O arm64，148 KB）
- `Libraries/libiPhone-lib.a` 203 MB、`libil2cpp.a` 67 MB、`baselib.a`
- `Data/` 885 MB，其中 `Data/Raw/` 491 MB 是 StreamingAssets（游戏数据：Core + 5 个扩展包）

已剔除 `IL2CPP/build/deploy_x86_64`（Intel mac 工具链，runner 是 arm64，用不到）。

## 触发构建

仓库 → Actions → `build-ios-ipa` → Run workflow。或直接 push 到 `main`。

流程：
1. `macos-14` runner，安装 7-Zip
2. 解 7 卷到 `work/iOS`
3. 选 Xcode 15.x（`Xcode_15.4` 起逐个探测）
4. `xcodebuild archive -configuration Release -destination 'generic/platform=iOS'`，全程 `CODE_SIGNING_ALLOWED=NO`
5. 从 `.xcarchive/Products/Applications/*.app` 打 `Payload/` + zip → `RimWorld-unsigned.ipa`
6. 上传 artifact `RimWorld-unsigned-ipa`

预期耗时 60–150 分钟（1087 个 cpp 编译是主项）。日志 artifact `build-log` 里是完整 `archive.log`。

## 产物信息

| 项 | 值 |
|---|---|
| Bundle ID | `com.yg.rimworldios` |
| App 名 | `RimWorldbyLudeonStudios.app` |
| 版本 | 1.6 (1) |
| 最低系统 | iOS 13.0 |
| 架构 | arm64 |
| 设备族 | iPhone + iPad（`TARGETED_DEVICE_FAMILY = 1,2`） |
| 图形 API | Metal |
| 色彩空间 | Gamma |
| 输入 | Legacy Input Manager（触屏层自绘） |
| 脚本后端 | IL2CPP |

## 移植层改了什么

原版是 Windows/Mono 的 `Assembly-CSharp.dll`，整个程序集反编译后重建为可 AOT 的 C# 源码（9219 个文件），再做以下改造：

**输入**（`Verse/PortInput.cs`、`Verse/PortEvent.cs`）
- 单指 = 左键（Unity legacy Input 在 iOS 上原生映射），单指长按 500 ms = 右键，双指轻点 = 右键，双指拖拽 = 中键平移，双指捏合 = 滚轮缩放
- 全工程 22 处 `Input.GetKey*`、36 处右键判断重定向到 PortInput / PortEvent，业务代码一行未改
- `PortEvent.BeginInject()` 在 Repaint pass 里改写 `Event.current` 为 `MouseDown button=1`，让整棵 IMGUI 树走右键分支

**平台层**（`Verse/PortPlatform.cs`）
- 只读数据路径 = `Application.streamingAssetsPath`（iOS 上是 `App.app/Data/Raw`），可写路径 = `persistentDataPath`
- 存档 → `persistentDataPath/SaveData`，Mod → `persistentDataPath/Mods`
- UI 缩放按屏幕短边自动分档（1.25 / 1.5 / 1.75 / 2.0），画质按内存分档

**AOT 适配**
- Burst 直调桩（`MapGenUtility` / `FastTileFinder` / `PlanetLayer`）整块移除
- `Assembly.LoadFrom` 走 iOS 守卫：Mod 的 .dll 跳过并打警告，XML 内容照常加载
- `MemoryMappedFileSpanWrapper` 改为 `File.ReadAllBytes` 缓冲（iOS 无 MMF）
- `PortAudioLoader` 手写 RIFF 解析替代 NAudio 的 ACM 路径（msacm32.dll 在 iOS 不存在）
- `link.xml` 全量 preserve Assembly-CSharp（Def 系统 / Comp 系统 / Mod 加载全走反射）

**Steamworks**（`SteamworksStub`）
- `com.rlabrecque.steamworks.net.dll` 398 KB → 34 KB 同签名桩件，`SteamAPI.Init()` 恒 false
- Workshop / Overlay / SteamDeck 分支全部自然关闭，`UIRoot_Entry` 的「Steam 未启动」对话框在 iOS 上抑制

**扩展包资源**
- 5 个官方 DLC 的 AssetBundle 原样进 `Data/Raw/*/AssetBundles/`，运行时 `AssetBundle.LoadFromFile` 读取
- `ModAssetBundlesHandler.BundleSuffixForCurrentOs` 对 iOS 返回空串（官方包无平台后缀）

## 签名

ipa 是未签名的，`Payload/RimWorldbyLudeonStudios.app` 里的二进制没有 entitlements 也没有 provisioning profile。自己签：

```bash
# 用 ldid（越狱/TrollStore）
ldid -S entitlements.plist Payload/RimWorldbyLudeonStudios.app/RimWorldbyLudeonStudios

# 或用 codesign（自签证书 / 开发者证书）
codesign -f -s "Apple Development: you@example.com" \
  --entitlements entitlements.plist \
  --deep Payload/RimWorldbyLudeonStudios.app

zip -qry RimWorld-signed.ipa Payload
```

需要 `application-identifier`、`get-task-allow`、`com.apple.developer.team-identifier` 三个 entitlement，按你的证书填。

## 已知限制

- 第三方 Mod 的 `.dll` 在 IL2CPP 下无法运行时加载，只有 XML 类 Mod 可用
- 首次启动要扫 491 MB StreamingAssets 建 Def 数据库，A 系列芯片约 20–40 秒
- iOS 无滚轮，滚动靠 PortInput 注入 `GUI.BeginScrollView` 的位移
- 平板横屏体验最好；竖屏可用但 UI 密度按短边算会偏小
