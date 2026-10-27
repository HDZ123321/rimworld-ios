# build 13 — 缩短 il2cpp 构建时间（OptimizeSize + Medium 裁剪）

打包日期 2026-10-27。这一版不改游戏逻辑，只改 IL2CPP 的代码生成与裁剪档位，
目标是压缩 CI 里 Archive 阶段的耗时。

## 0. 背景：Archive 的 35 分钟全在 il2cpp

run #25（build 12）的 Archive 段实测总 2226.9 秒，按日志时间戳拆开：

| 阶段 | 耗时 | 占比 |
| --- | --- | --- |
| il2cpp `--compile-cpp`（GameAssembly 的 Run Script → bee_backend） | 2146.2 s = **35m46s** | **96.4%** |
| `builtin-copy` 拷 602 MB Data/Raw | 23.3 s | 1.0% |
| 最终 `clang++ -Xlinker` 链接 UnityFramework | 11.9 s | 0.5% |
| ibtool / actool / strip / chown 等 | ~45 s | 2.1% |

铁证是 bee_backend 自己打的这行：

```
Starting: .../bee_backend --verbose --threads=3 --profile=...
ExitCode: 0 Duration: 35m:46s
```

慢的三个原因：

1. **编译单元太大**。build 12 的 `il2cppOutput` 是 722 个 `.cpp`、1091.4 MB 源码，
   其中 `Il2CppInvokerTable.cpp` 单个 24 MB，`GenericMethods__5/6/7.cpp` 各 3.7 MB。
2. **只有 3 个核**。`macos-14` 是 3 vCPU，`--threads=3` 已打满，等价 6438 CPU-秒。
3. **裁剪没开**。`il2cppCodeGeneration: 0`（OptimizeSpeed，构建最慢）、
   `managedStrippingLevel: 1`（Low）、`stripEngineCode: 0`。

## 1. 改了哪两行（`Assets/Editor/PortBuild.cs`）

```csharp
        // build 13 起 Low → Medium：只裁 BCL 与未用引擎模块。link.xml 已对 Assembly-CSharp 全保留，游戏逻辑不受影响。
        PlayerSettings.SetManagedStrippingLevel(BuildTargetGroup.iOS, ManagedStrippingLevel.Medium);
        PlayerSettings.SetIl2CppCompilerConfiguration(BuildTargetGroup.iOS, Il2CppCompilerConfiguration.Release);
        PlayerSettings.SetIl2CppCodeGeneration(NamedBuildTarget.iOS, UnityEditor.Build.Il2CppCodeGeneration.OptimizeSize);
```

`OptimizeSize` 就是 Unity 界面上 “IL2CPP Code Generation = Faster (smaller) builds”，
官方描述即 “缩短构建时间，代价是运行时性能下降”。

## 2. 效果：生成代码量已实测下降 35%

同一套 Assets 重新导出后，本机 `il2cppOutput` 目录对比：

| 项 | build 12 | build 13 | 变化 |
| --- | --- | --- | --- |
| `.cpp` 文件数 | 722 | 478 | **-33.8%** |
| 源码总量 | 1091.4 MB | 709.6 MB | **-35.0%** |
| `Il2CppInvokerTable.cpp` | 24.0 MB | 12.5 MB | -48% |

生成代码少了三分之一，clang 的活就少了三分之一，CI 的 il2cpp 段预期同比缩短。

### 2.1 CI 实测结果（run #26，`3d1b2f8`）

| 项 | run #25 (build 12) | run #26 (build 13) | 变化 |
| --- | --- | --- | --- |
| il2cpp 段（bee_backend 自报 `Duration`） | 35m46s (2146.2 s) | **17m42s (1064.3 s)** | **-50.4%** |
| Archive 步骤总时长 | 37.1 min (2226.9 s) | 18.5 min (1112.7 s) | **-50.0%** |
| `builtin-copy` 拷 Data/Raw | 23.3 s | 11.1 s | -52% |
| 最终 UnityFramework 链接 | 11.9 s | 4.1 s | -66% |
| CI 全流程 | 43.5 min | **19.1 min** | **-24.4 min** |

`bee_backend` 那两行是直接证据：

```
run #25: ExitCode: 0 Duration: 35m:46s
run #26: ExitCode: 0 Duration: 17m:42s
```

收益超过源码量降幅（35%），因为编译单元少了 244 个，每个单元的固定开销
（预处理、模板实例化上下文）随之消失。

产物：`out/RimWorld-unsigned-b13.ipa`，655,645,690 字节（625.3 MB，比 b12 小 8.6 MB），
sha256 `3A6F69C256E129AE2C78BB31F4B1BCCF5124F8D6DB54C552F7950E90B2FB0E6E`。
ipa 内部：`global-metadata.dat` 23.8 → 22.7 MB，`UnityFramework` 132.1 → 84.4 MB。

## 3. 风险与回归清单

`OptimizeSize` 只影响代码生成策略，不改变语义，运行时正确性风险低，代价是速度。
`Medium` 裁剪会移除未引用的 BCL 类型，RimWorld 的反射路径必须逐条验：

- [ ] 启动到主菜单，无 `MissingMethodException` / `TypeLoadException`
- [ ] 新开一局，地图生成完成
- [ ] 读档（含 Mod 存档）成功
- [ ] XML Def 加载：`DirectXmlLoader` 按 `Class=` 字符串 `Type.GetType` 找类型
- [ ] `DefDatabase<T>` 的 `MakeGenericType` 索引构建
- [ ] Mod 加载（本地 Mod 目录读 def）
- [ ] 存档写盘 + 重进读取

`Assets/link.xml` 已把 `Assembly-CSharp`、`Assembly-CSharp-firstpass` 以及反射用到的
UnityEngine 模块全部 `preserve="all"`，所以游戏程序集本身不会被裁。真正暴露在裁剪下的是
BCL（`System.*`）和未被 link.xml 列出的引擎模块。

若上面某条挂掉，回退方式是把 `managedStrippingLevel` 改回 `Low`，
单独保留 `OptimizeSize`——构建时间的收益主要来自后者。

## 4. 已排除的方案

| 方案 | 结论 |
| --- | --- |
| `macos-14-xlarge`（6 vCPU） | il2cpp 段能腰斩，但私有仓库按 20 倍分钟计费，不值 |
| 缓存 `il2cppOutput` 产物 | 内容由 C# 代码哈希决定，改一行 C# 就全失效，命中率接近零 |
| 用 `-O1` 降 il2cpp 单文件优化级别 | bee_backend 用 il2cpp 内部生成的编译命令，不读 Xcode 的 `GCC_OPTIMIZATION_LEVEL`，无稳定通道 |
| sccache 接管 il2cpp 编译 | run #25 实测 sccache 100% 命中但只覆盖 45 个 Objective-C++ 文件；这 478~722 个 `.cpp` 由 bee_backend 自己调 clang++，不读 `CC` |
