# build 9：音效真正延迟解码

## 问题

build 7 的「AudioClip 懒加载」没有缩短任何加载时间。真机日志（`port-20261025-180950.log`）显示
`ExecuteToExecuteWhenFinished` 仍然是 **27,327ms**（build 6 是 26,888ms）：
3,733 张 AudioClip 确实被推迟了（`ReloadAll<AudioClip>` 各 mod 从秒级掉到 6ms），
但成本原封不动地搬到了 `SubSoundDef.ResolveReferences` 的延迟委托里。

## 根因

`Work/port/build/src/Verse.Sound/SubSoundDef.cs`：

```csharp
LongEventHandler.ExecuteWhenFinished(delegate {
    resolvedGrains.Clear();
    foreach (AudioGrain grain in grains)
        foreach (ResolvedGrain rg in grain.GetResolvedGrains())
            resolvedGrains.Add(rg);
    distinctResolvedGrainsCount = resolvedGrains.Distinct().Count();
});
```

`AudioGrain_Clip.GetResolvedGrains()` 里 `ContentFinder<AudioClip>.Get(clipPath)`
会把推迟的 clip 照样全量解码 —— 只是发生在 `ExecuteToExecuteWhenFinished`
的委托里，仍然在同一个 9,469 个后置动作的循环内、仍然在主线程同步跑。

## 修法：ResolvedGrain 只记路径，播到才解码

`ResolvedGrain_Clip` 新增懒路径模式：

```csharp
public string lazyClipPath;
private bool lazyResolved;

public ResolvedGrain_Clip(string clipPath)
{
    lazyClipPath = clipPath;
    clip = null;
    duration = 0f;
}

public AudioClip GetClip()
{
    if (!lazyResolved && lazyClipPath != null)
    {
        lazyResolved = true;
        clip = ContentFinder<AudioClip>.Get(lazyClipPath);
        if (clip != null) duration = clip.length;
        else Log.Warning("[iOS/Port] Lazy audio clip not found: " + lazyClipPath);
    }
    return clip;
}
```

三处关键配套：

1. **`Equals` / `GetHashCode` 必须按路径比**。`SubSoundDef.ResolveReferences` 里
   `resolvedGrains.Distinct()` 会遍历比较所有 grain —— 只要 `Equals` 落在 `clip` 字段上，
   整个 3,733 张就会在那里被一次性解码，白改。
2. **`SubSoundDef.TryPlay()`** 把 `resolvedGrain_Clip.clip` 换成
   `GetClip()`，拿不到就直接 return（缺音效时静默，不抛异常）。
3. **`SubSustainer.StartSample()`** 在算 `duration` 之前先 `GetClip()`，
   否则循环音（火焰、雨、机器）的循环长度是 0。

## 结果

- `dotnet build -p:UseSteamStub=true` → 0 错误 / 26 警告，`Assembly-CSharp.dll` = 17,481,216 B
- Unity 导出：`result: Succeeded` / `totalSize 2708.8 MB` / **`totalErrors: 0`**
- 预期效果：`ExecuteToExecuteWhenFinished` 从 27 秒降到 3–5 秒量级，
  剩余部分主要是 5,326 张 Texture2D 与图集烘焙（约 7 秒）。

## 副作用

- 首次播放某个音效时会有一次同步解码（单个 clip，毫秒级），可能造成一两帧的微卡。
- `SoundDef.Duration` 对未解码的 grain 返回 0；唯一消费者是
  `RimWorld/GravshipAudio.cs` 的循环计时，影响可忽略。
- 内存占用下降：不再常驻 3,733 张 AudioClip，只保留实际播过的。
