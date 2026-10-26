# 01 — Inventory: repo vs Studio

Date: 2026-10-26. Branch `arena/ocean-sound-and-audit`, HEAD `7ac5683` (37 commits on top of `0d18c1b`).
Studio: place **BRINE**, placeId `121237182638386`, plugin 4.0.0, Studio 0.744.0.7441077, edit peer `edit-fa1fc734`.

Every number here comes from a command or a read-back listed in *Evidence*. Nothing is estimated.

> **Environment note.** This session started in a fresh sandbox: no local clone, no `.mcp/`, no
> `.tools/`, no `probes/`. The clone was restored from the GitHub remote at `7ac5683`, the bridge
> client was rebuilt, and `bash tools/setup-tools.sh` restored the pinned toolchain (Luau 0.736,
> styLua 2.5.2, selene 0.31.0). `.tools/`, `.mcp/`, `probes/` are gitignored or outside the repo;
> none is committed.

---

## 1. Repo health

| Check | Command | Result | Baseline | Verdict |
|---|---|---|---|---|
| Smoke test | `node tools/smoke-test.js` | `passed=83 failed=0 buoyCalls=0 lookups=88` (4 warn lines) | 83 / 0 | match |
| Syntax (Luau compiler present) | `node tools/check-syntax.js` | `All 23 Luau file(s) parsed successfully` | 23 files | match |
| Project tree | `node tools/validate-project.js` | 7 model files, `Errors: 0 \| Warnings: 0` | consistent | match |
| Luau compile, every file | `.tools/bin/luau-compile <file>` over `find src -name '*.luau'` | 41 files, **0 failures**, exit 0 | exit 0 per file | match |
| Dead config keys | `node tools/find-dead-config.js` | Settings: **0 config keys** detected, "no dead keys"; IslandConfig: 13 keys, "no dead keys" | — | see D-15 |
| Call graph | `node tools/call-graph.js` | 41 module-function entries, no orphan module | — | pass |

**Caveat recorded for the record:** `check-syntax.js` is *not* authoritative. It prefers
`.tools/bin/luau-compile` and only falls back to `luaparse` (Lua 5.1). In a clean sandbox where
`.tools/` was never installed, the fallback reports **3 false failures** —
`SwimClient.client.luau` (`[324:17] <expression> expected near 'if'`: a Luau `if-then` expression),
`AmbientSea.client.luau` (`[135:16]`, same cause: `local reverb = if murk > 0.5 then …`),
`ParallelWorker.client.luau` (`[76:14] unexpected symbol ':'`: the nested table type
`{ [Vector3]: { number } }`). All three are valid Luau and compile clean with `luau-compile`.
Do not treat those three as defects; see D-16.

**Dead modules:** none. Every module in `src/` is reachable from a `require` in a script
(`grep -rn 'require(' src/`, 40 call sites). `Gerstner/Settings/init.luau:1` requires
`script.Parent`, which is the self-reference that makes `find-dead-config` report 0 keys for it.

---

## 2. Repo vs Studio parity

`survey_place` returned **81 scripts / 4056 instances** in the edit DataModel. 41 repo `.luau`
files map onto **45** Studio counterparts (the `Ship` singleton is deployed three times):
**41 match byte-for-byte, 4 differ.** Two very large scripts (`IslandGenerator` 2335 lines,
`FloatingObjectGenerator` 2335 lines) were over the survey's per-script cap and were read back
individually with `script_read`; both match exactly.

| Status | Repo file | Studio path | Note |
|---|---|---|---|
| match | `ReplicatedStorage/Gerstner/init.luau` | `ReplicatedStorage.Gerstner` | 340 lines |
| match | `Gerstner/HeightLookup.luau` | `ReplicatedStorage.Gerstner.HeightLookup` | 288 |
| match | `Gerstner/Helper.luau` | `ReplicatedStorage.Gerstner.Helper` | 327 |
| match | `Gerstner/Types.luau` | `ReplicatedStorage.Gerstner.Types` | 27 |
| match | `Gerstner/Settings/init.luau` | `ReplicatedStorage.Gerstner.Settings` | 179 |
| match | `Gerstner/Serial/Setup/init.luau` | `ReplicatedStorage.Gerstner.Serial.Setup` | 527 |
| match | `Gerstner/Serial/ZoneManager/init.luau` | `ReplicatedStorage.Gerstner.Serial.ZoneManager` | 234 |
| match | `Gerstner/Serial/BoatManager.luau` | `ReplicatedStorage.Gerstner.Serial.BoatManager` | 74 |
| match | `FloatingObjectGeneration/WaveFloat.luau` | `ReplicatedStorage.FloatingObjectGeneration.WaveFloat` | 236 |
| match | `FloatingObjectGeneration/FloatingObjectConfig.luau` | `…FloatingObjectConfig` | 397 |
| match | `FloatingObjectGeneration/FloatingObjectGenerator.luau` | `…FloatingObjectGenerator` | 2335 |
| match | `IslandGeneration/IslandGenerator.luau` | `…IslandGenerator` | 1088 |
| match | `IslandGeneration/Density.luau` | `…Density` | 28 |
| match | `IslandGeneration/Discovery.luau` | `…Discovery` | 131 |
| match | `IslandGeneration/Placement.luau` | `…Placement` | 155 |
| match | `IslandGeneration/Presentation.luau` | `…Presentation` | 138 |
| match | `IslandGeneration/Proximity.luau` | `…Proximity` | 76 |
| match | `Octree.luau` | `ReplicatedStorage.Octree` | 372 |
| match | `ShipHandling/ShipDrive.luau` | `ReplicatedStorage.ShipHandling.ShipDrive` | 148 |
| match | `ShipHandling/ShipGuard.luau` | `ReplicatedStorage.ShipHandling.ShipGuard` | 109 |
| match | `Swimming/SwimModel.luau` | `ReplicatedStorage.Swimming.SwimModel` | 140 |
| match | `Fishing/FishingSounds.luau` | `ReplicatedStorage.Fishing.FishingSounds` | 63 |
| match | `HandHolding/HandHoldingConfig.luau` | `ReplicatedStorage.HandHolding.HandHoldingConfig` | 38 |
| match | `ServerScriptService/HandHoldingServer.server.luau` | `ServerScriptService.HandHoldingServer` | 606 |
| match | `ServerScriptService/IslandGenerationServer.server.luau` | `ServerScriptService.IslandGenerationServer` | 51 |
| match | `StarterPlayerScripts/AmbientSea.client.luau` | `StarterPlayer.StarterPlayerScripts.AmbientSea` | 192 |
| match | `StarterPlayerScripts/SwimClient.client.luau` | `…SwimClient` | 329 |
| match | `StarterPlayerScripts/DiveSplash.client.luau` | `…DiveSplash` | 99 |
| match | `StarterPlayerScripts/FloatingObjectsClient.client.luau` | `…FloatingObjectsClient` | 54 |
| match | `StarterPlayerScripts/HandHoldingClient.client.luau` | `…HandHoldingClient` | 98 |
| match | `StarterPlayerScripts/OceanParallel/init.client.luau` | `…OceanParallel` (LocalScript) | 379 |
| match | `StarterPlayerScripts/OceanParallel/ParallelWorker.client.luau` | `…OceanParallel.ParallelWorker` | 396 |
| match | `Workspace/FloatingGui.luau` | `Workspace.FloatingGui` | 189 |
| match | `Workspace/StickFishingRod/FishPose.luau` | `StarterPack.StickFishingRod.FishPose` | 26 |
| match | `Workspace/StickFishingRod/FishingServer.server.luau` | `StarterPack.StickFishingRod.FishingServer` | 719 |
| match | `Workspace/StickFishingRod/FishingClient.client.luau` | `StarterPack.StickFishingRod.FishingClient` | 412 |
| match | `Workspace/singletons/Ship/Handler.server.luau` | `Workspace.{WoodenShip,Boathouse,MisoSoup}.Handler` | 364 ×3 |
| match | `Workspace/singletons/Ship/Client.client.luau` | `Workspace.Boathouse.Client` | 269 |
| match | `Workspace/singletons/Ship/Client.client.luau` | `Workspace.MisoSoup.Client` | 269 |
| **differs** | `Workspace/singletons/Ship/Client.client.luau` | `Workspace.**WoodenShip**.Client` | repo 269 / Studio 243 lines — **stale** (D-01) |
| **differs** | `ReplicatedStorage/IslandGeneration/IslandConfig.luau` | `…IslandConfig` | repo 256 / Studio 251, 23 diff lines (D-02, D-03) |
| **differs** | `ServerScriptService/FloatingObjectGenerationServer.server.luau` | `ServerScriptService.FloatingObjectGenerationServer` | repo 72 / Studio 73 (D-07) |
| **differs** | `Workspace/StickFishingRod/FishingConfig.luau` | `StarterPack.StickFishingRod.FishingConfig` | 77/77 lines, GUI block differs (D-08) |

**Reading of the direction of each drift:** in D-01, D-02 and D-07 the *repo is newer* than Studio
(Studio kept an older push), so the repo is authoritative. In D-03 and D-08 *Studio holds the live
tuning* the user has actually played, so Studio is authoritative and the repo would regress if
built from source. This split is why each fix needs an explicit direction, not a blind sync.

### Repo files with no Studio counterpart

None. All 41 map.

### Studio scripts with no repo counterpart (18 of the 81)

These are outside `default.project.json` and would **not** survive a rebuild from the repo:

| Script / tree | Lines | Area | Assessment |
|---|---|---|---|
| `ReplicatedStorage.Gerstner.init` | 341 | ocean | **Duplicate** of `ReplicatedStorage.Gerstner` (identical hash `13697039`, same 11950 bytes). Nothing requires it (D-06). |
| `ReplicatedStorage.UsefulFunctions.Module` | 835 | third-party | Not in repo (D-11) |
| `Workspace.MODULE.VoxBreaker` (+ `PartCache`, `PartCache.Table`) | 1407 / 192 / 107 | third-party | Not in repo (D-11) |
| `Workspace.SingleHeightLookup.LookupTesting` | 15 | debug | Runs `HeightLookup.Lookup(..., 'PRECISE', …)` every `Stepped` frame forever (D-09) |
| `Workspace.RoughSeaArea.RoughSea` + `ServerStorage.OceanEvents.SeaStuff.RoughSeaArea.RoughSea` | 19 ×2 | ocean zones | Same source twice (D-10) |
| `Workspace.Whirlpool.Whirlpool` + `ServerStorage.OceanEvents.SeaStuff.Whirlpool.Whirlpool` | 41 ×2 | ocean zones | Same source twice (D-10) |
| `Workspace.Boathouse.Lights.Part{,12–16}.Lantern` | 1 ×6 | decoration | Empty `Script`s (0 bytes) |
| `ServerStorage.Islands.*/*.ProximityDelete` | 47 ×9 | islands | Premade-island payload, `ServerStorage` only |
| `ReplicatedStorage.UsefulFunctions.Module.System.*` | 15 ×12 | third-party UI | Part of the UsefulFunctions tree |

---

## 3. Studio leftovers (debug hooks)

The prompt listed five leftovers to look for. **None of them is in the current edit DataModel.**

| Expected leftover | Searched | Found |
|---|---|---|
| `args_gen_dbg_on`, `args_gen_dbg_fix` | attributes on every instance under the 9 game services; `script_grep` over all 81 scripts | **no** |
| `SoftResponsiveness = 24` on floating objects | same | **no** |
| `args_miso_noguard_on` | same | **no** |
| `DbgTicks`, `DbgWait`, `DbgRough`, `DbgUnder` on `SoundService.AmbientSea` | same | **no** — and `SoundService.AmbientSea` does not exist in edit mode at all (the client script builds it at runtime) |
| `203785492` asset id in any script | `script_grep` | **no** |

The only attributes anywhere in the game tree are **9**, none of them debug switches:

| Instance | Class | Attributes |
|---|---|---|
| `Workspace.MisoSoup` | Model | `Draft=-7.3`, `SinkRestOffset=2.4` (D-13) |
| `Workspace.WoodenShip` | Model | `Draft=5.5`, `SinkRestOffset=-2` |
| `Workspace.Boathouse` | Model | `Draft=3.5` |
| `ServerStorage.FloatingObjects.Common.Raft` | Model | `Weight=1` |
| `ServerStorage.FloatingObjects.Rare.Container` | Model | `Weight=3` |
| `Workspace.Camera.EclipseBlastDisplay` | Folder | `EclipseTransient=true` (plugin) |
| `ReplicatedStorage.XocoatlSaves.ColorPresets.My Palette` | Folder | `Xocoatl_FolderId` (plugin) |
| `ServerStorage.Eclipse Animator Saves…` ×2 | Folder | plugin |

Conclusion: either the session that wrote the prompt already reverted them, or they existed only
for the duration of a playtest. **They must be re-checked in Play before the final report**, because
runtime attributes on spawned floating objects cannot appear in edit mode. That check is deferred to
prompt 08/09 and is stated as *not verified* there.

---

## 4. Sounds

34 `Sound` objects exist in the edit DataModel; 31 belong to Studio plugins (`CoreGui`,
`PluginGuiService`) and 3 belong to the game.

| Path | SoundId | Volume | Looped | IsPlaying | Verdict |
|---|---|---|---|---|---|
| `Workspace.WoodenShip.Prim.Splash` | `167123203` | **0** | true | **true** | Silent loop, unapproved asset (D-04) |
| `Workspace.Boathouse.Prim.Splash` | `167123203` | **0** | true | **true** | Silent loop, unapproved asset (D-04) |
| `Workspace.Boathouse.Motor.Engine` | `8916893206` | 2 | true | true | Loads clean; volume 2 is loud for an engine bed |

`Workspace.MisoSoup` and `Workspace.WoodenShip` have **no** engine `Sound` at all, while
`Boathouse` does — the three ships are not built the same (relevant to prompt 07).

The `AmbientSea` bed is **not** visible here: `AmbientSea.client.luau` creates its ten sounds at
runtime, so a sound-by-sound audit including the two unused IDs (calming `131586509457092`, cave
`273398061`) has to happen in Play (prompt 05).

---

## 5. Asset warnings (console)

`get_console_output` over the whole edit session: **45 lines, 45 `MessageWarning`, 0 errors**
(`totalHistory` matches, nothing dropped). Exactly two distinct messages:

| Count | Message | Attributed to |
|---|---|---|
| 30 | `ContentId: rbxassetid://167123203 failed due to: Asset is not approved for the requester` | `Workspace.WoodenShip.Prim.Splash`, `Workspace.Boathouse.Prim.Splash` — both ours (D-04) |
| 15 | `ContentId: rbxassetid://203785492 failed due to: Asset type does not match requested type` | **unattributed**: no instance property (`SoundId`, `Texture`, `MeshId`, `Image`, `ColorMap`, `Meta`, `NormalMap`, `RoughnessMap`, `EmissiveMap`, sky faces, `CursorIcon`) and no script in the game tree contains this ID (D-05) |

The 2:1 ratio is exactly the 2 Splash objects vs 1 unknown consumer. The warnings repeat on a
~13 s cycle, which matches an asset-retry backoff, not gameplay.

---

## 6. Scripts on the wrong side

| Rule | Check | Result |
|---|---|---|
| No server script reads `LocalPlayer` / `CurrentCamera` | `grep -n 'LocalPlayer\|CurrentCamera'` over all `*.server.luau` | **0 hits** — clean |
| No client script mutates replicated state | manual review of the 8 client scripts' writes | `AmbientSea` and `SwimClient` write only `Lighting`, `SoundService` and local player state; `FloatingObjectsClient` fires one `RemoteEvent` (`CameraReport`); `Ship/Client` creates movers **locally** and removes them on exit (by design, ROADMAP 2.5/2.6). **No violation found.** |

Environment facts worth recording for later prompts (read in edit mode):

- `Workspace.Ocean` exists but has **0 descendants** — the planes are built at runtime by
  `OceanParallel`.
- `Workspace.Part` **exists**: `Part`, size `121 × 230 × 98`, position
  `16.156, -44.758, 174.041`, `Anchored = true`. The protected platform slab is intact.
- `Lighting`: `ClockTime 14.5`, `Brightness 1.5`, `GlobalShadows true`, `FogStart 0`,
  `FogEnd 100000`, `FogColor (0.753, 0.753, 0.753)`, `ExposureCompensation 0`;
  `Atmosphere Density 0.38, Haze 1, Offset 0, Color (1,1,1)`.
  The seam fog (500→880) and murk fog are runtime-only, so they cannot be confirmed here.
- `StarterPlayerScripts`: `OceanParallel`, `HandHoldingClient`, `FloatingObjectsClient`,
  `SwimClient`, `DiveSplash`, `AmbientSea` — 6 LocalScripts, all with a repo source.
- `ServerStorage`: `StoredBaseplate`, `Islands`, `FloatingObjects`, `OceanEvents`,
  `Eclipse Animator Saves`, `Fish`.
- `ServerBoat` (the physics reference, must not change): 16 descendants —
  `Sail` (MeshPart, collide), `Base` (MeshPart, collide), `Main` (Part, **CanCollide false**),
  5 `Attachment`s on `Main` (`TopLeft`, `BottomLeft`, `TopRight`, `BottomRight`, `Center`),
  `VehicleSeat` (CanCollide false) with `BodyPosition` + `BodyGyro` + `BodyVelocity`, 3
  `ManualWeld`s, and its own `Handler` Script (93 lines, no repo counterpart). All parts
  `Friction 0.3`, `Elasticity 0.5`, `Massless false`. **This is the recorded reference state.**

---

## 7. Remotes

| Remote | Class | Created by | Fired/listened |
|---|---|---|---|
| `ReplicatedStorage.FloatingObjectGeneration.CameraReport` | RemoteEvent | ships in the folder via Rojo (`.model.json`); server re-creates it if missing (`FloatingObjectGenerationServer:36`) | client → server (`FloatingObjectsClient`); both sides present |
| `ReplicatedStorage.HandHolding.HandHoldingEvent` | RemoteEvent | `.model.json` | `HandHoldingClient:15` + `HandHoldingServer:18` — both sides |
| `ReplicatedStorage.Gerstner.Serial.ZoneManager.EditZone` | RemoteEvent | `.model.json` | `ZoneManager` uses `FireAllClients`/`OnClientEvent` — both sides |
| `ReplicatedStorage.Gerstner.Serial.ZoneManager.ZoneUpdated` | BindableEvent | `.model.json` | in-process only |
| `Remotes.FishEvent`, `Remotes.Action` | RemoteEvent | **created at runtime** by `FishingServer.server.luau:55,58` (`FindFirstChild(...) or Instance.new(...)`) | `StarterPack.StickFishingRod` — both sides |
| `UsefulFunctions…AnswerServer` / `.Answer` ×4 | Remote/Bindable pair | third-party tree | part of UsefulFunctions |

**One-sided names: none found.** The fishing remotes are created at runtime rather than shipped as
instances, which works but means the client's `WaitForChild` can hang if `FishingServer` fails to
start first — a latent ordering dependency (P3, prompt 06).

---

## 8. Documentation drift

Claims checked against the source, with the command that settles them:

| Doc claim | Source evidence | Verdict |
|---|---|---|
| ROADMAP 1.5: `Settings.DEBUG = RunService:IsStudio()` | `Gerstner/Settings/init.luau:100` | **true** |
| ROADMAP 2.3: `GRID_SETTINGS.SECONDARY_PLANES` default 8 | `Settings/init.luau:112` = 8; clamped 0–8 at `Setup/init.luau:481` | **true** |
| ROADMAP 2.2: `RefreshForceLimits()` recomputes mover limits | `Ship/Client.client.luau:106,116,170` | **true** |
| ROADMAP 3.2: `OceanParallel` calls `HeightLookup.ClientInit` | `OceanParallel/init.client.luau:264` | **true** |
| ROADMAP 0.4 / 3.2: `SET_SETTINGS` called with grid values | `Settings/init.luau:177`, `OceanParallel/init.client.luau:88`, `ParallelWorker:35` | **true** |
| Prompt 03: `PERF.REPORT_EVERY` is 0 in the repo | read from `Settings` (only Studio sets 300) | **true** |
| Prompt 02: `FAR_WRITE_EVERY = 3`, `UV_WRITE_EVERY = 3`, `MeshDetailDistance = 120`, `LowRenderDistance = 200`, `MaxChunkRenderDistance = 800` | `Settings/init.luau:164,165,120,117,121`; consumed at `ParallelWorker:104,105,135,141` | **all true** |
| Prompt 02: calm `0.3` … rough `1` | `Gerstner/init.luau:141` `SEA_STATE_CALM = 0.3`, `:149` lerp to 1 | **true** (there is no `SEA_STATE_ROUGH` constant — rough is the literal 1; the prompt's phrasing is slightly off) |
| `docs/work-notes/ocean/NOTES.md` performance table | not re-measured yet | **not yet verified** — prompt 03 |
| Rule: fishing grab is a `DragDetector` | `FishingServer.server.luau:320–375` (`DRAG_STYLE`, `makeDragDetector`); **no** `AlignPosition`/`AlignOrientation` in either fishing file | **true** |
| Rule: `ServerBoat` unchanged | 93-line `Handler`, `BodyPosition/BodyGyro/BodyVelocity` on the seat — a different mechanism from the other three ships | **true** (and must stay so) |

Contradictions between the prompt and the live place, recorded rather than silently followed:
**the five debug hooks do not exist** (§3), and **`Workspace.Ocean` is empty in edit mode**, so any
prompt that says "look at the ocean mesh in Studio" only applies during Play.

---

## Evidence index

| # | Command |
|---|---|
| E1 | `node tools/smoke-test.js`, `node tools/check-syntax.js`, `node tools/validate-project.js`, `luau-compile` ×41 |
| E2 | `survey_place {includeSource:true, maxScriptBytes:400000}` → 81 scripts, 4056 instances |
| E3 | `script_read` on `IslandGenerator`, `FloatingObjectGenerator`, `Gerstner.init` |
| E4 | parity script: 45 pairs, 41 match / 4 differ |
| E5 | `probe` (edit): attribute sweep over 9 game services → 9 attributes, 0 debug hooks |
| E6 | `probe` (edit): all `Sound` descendants → 34 total, 3 game |
| E7 | `get_console_output {limit:3000}` → 45 warnings, 2 distinct |
| E8 | `probe` (edit): `Workspace.Part`, `Workspace.Ocean`, `Lighting`, `Atmosphere`, `ServerBoat` |
| E9 | `script_grep` over 81 scripts for debug-hook and asset-id patterns → 0 matches |
