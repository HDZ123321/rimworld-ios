# build 3

Restores the five official expansions to `StreamingAssets/Data` (492 MB total,
matching the Steam install) and fixes the dead language button on iOS touch.

## Language switch

Three independent defects stacked up:

1. `PortInput.mousePosition` returned `syntheticMousePos` whenever it was
   non-zero, and `ResetTouchState()` never cleared it. After the first long
   press, `mousePosition` was frozen on that old point forever.
2. `FloatMenu.SetInitialSizeAndPosition()` positions itself from
   `UI.MousePositionOnUIInverted`, so the language menu opened at the stale
   coordinates.
3. `FloatMenu.UpdateBaseColor()` measures `Event.current.mousePosition` against
   the window and calls `Close()` + `Cancel()` once it is more than 95 px away.
   With the window at the stale spot that test fired on the very next frame —
   the menu flashed and vanished, so the button looked dead.

Fixes: only honour `syntheticMousePos` while a synthetic right/middle button is
actually held, clear it in `ResetTouchState()`, and disable the
"pointer is far away" auto-close for `FloatMenu`, `FloatMenuGrid` and
`Dialog_StyleSelection` under `PortInput.TouchMode` (`closeOnClickedOutside`
still closes them normally).

Separately, `LanguageDatabase.SelectLanguage()` queued the reload with
`doAsynchronously: true`, which runs `PlayDataLoader` on a background thread.
That path touches `Texture2D` / `AudioClip` / `Material`, throws
"can only be called from the main thread" on iOS, and
`RunEventFromAnotherThread()` swallowed it into a single `Log.Error` — so even a
successful menu click never changed the language. It now queues synchronously.

## DLC activation

`ModsConfig`'s static constructor only auto-activated expansions for which
`IsExpansionNew()` was true. A save that already recorded `knownExpansions`
(build 9 shipped all five) therefore treated the re-added DLCs as "known but
disabled" and left them off. The `IsExpansionNew` gate is now dropped: every
installed official expansion is force-activated. `knownExpansions` is still
appended for genuinely new ones, and `Prefs.Notify_NewExpansion()` is likewise
gated on newness so returning players do not get the popup again.

Note that DLC ownership itself never needed patching: `ModLister.TryAddMod()`
only consults `SteamApps.BIsDlcInstalled()` when `SteamManager.Initialized` is
true, and the Steamworks stub returns `false` from `SteamAPI.Init()`, so the
check is skipped entirely.
