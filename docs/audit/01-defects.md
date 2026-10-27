# 01 — Defects

Found during the audit pass. **Nothing was fixed in this pass** unless noted.
Severity: **P0** breaks play · **P1** visibly wrong · **P2** polish · **P3** debt.
"Prompt" is the pass that should fix it.

Each entry has evidence you can re-run, and — where I could — the direction the drift runs, because
in this repo *repo newer than Studio* and *Studio newer than repo* both occur and they need opposite
fixes.

---

## P1 — visibly wrong

### D-01 · `WoodenShip` runs a stale client script — **FIXED in Studio 2026-10-26**
- **Object:** `Workspace.WoodenShip.Client` (Studio) vs `src/Workspace/singletons/Ship/Client.client.luau` (repo).
- **Evidence:** read-back diff, **repo 269 lines / Studio 243 lines, 45 diff lines**. The Studio copy
  is missing the `seaSurfaceAt(zone, now)` helper (the 4-corner mean the repo's `WaveFloat.Solve`
  uses as the surface) and everything downstream of it. `Workspace.Boathouse.Client` and
  `Workspace.MisoSoup.Client` are **exact** copies of the repo file (269/269, 0 diff), so
  `WoodenShip` is the only ship on the old client.
- **Why it matters:** this is the mechanical cause of the brief's "`WoodenShip`'s minimum sink is
  poor" — the three ships do not run the same buoyancy client. It is also the only parity break in
  the ship tree.
- **Direction:** repo → Studio (repo is newer).
- **Fix in:** prompt **07**.
- **Done:** pushed `src/Workspace/singletons/Ship/Client.client.luau` to `Workspace.WoodenShip.Client`
  (`243 -> 269` lines) and read it back identical, 0 diff. All three hulls now run the same client.
  Not yet verified in Play by anyone: whether WoodenShip's minimum sink improves is the user's check.

### D-02 · `IslandConfig` is older in Studio than in the repo — **FIXED in Studio**
- **Object:** `ReplicatedStorage.IslandGeneration.IslandConfig`.
- **Evidence:** `repo 256 / studio 251 lines, 23 diff lines`. Studio lacks `MaxCachedRecords = 3000`
  and carries the pre-4.1 wording of the `MaxIslandRadius` comment.
- **Why it matters:** mostly none — `IslandGenerator.luau:826` reads
  `streamingConfig.MaxCachedRecords or 3000`, and the value is identical, so behaviour matches. Kept
  as P1 only because it is drift in a live-tuned file: the next person to change the cap in Studio
  will silently have no effect.
- **Direction:** repo → Studio.
- **Fix in:** prompt **08**.
- **Done:** the repo file (with D-03's real SFX values) was pushed to Studio and read back identical,
  258/258 lines.

### D-03 · The repo would ship **silent** island rise/sink audio — **FIXED**
- **Object:** `src/ReplicatedStorage/IslandGeneration/IslandConfig.luau` vs the Studio module.
- **Evidence:** repo `SoundId = "rbxassetid://0"`, `SoundVolume = 0.8` for **both** the rise and the
  sink SFX (`…/IslandConfig.luau`, placeholder comment "Replace the zero with your uploaded sound
  id"). Studio has `SoundId = "rbxassetid://9119681553"`, `SoundVolume = 2.5` (rise) and
  `"rbxassetid://1056170474"`, `1.15` (sink).
- **Why it matters:** a build from source loses the island arrival/departure audio entirely and
  fires `rbxassetid://0` load failures.
- **Direction:** **Studio → repo** (Studio holds live tuning; the repo holds a placeholder).
- **Fix in:** prompt **05** (sound) with prompt **08**.
- **Done:** commit `1cb64e2` brought the repo up to the live ids/volumes; both sides then pushed to the
  same source and read back identical.

### D-04 · Two `Splash` sounds loop forever at volume 0 on an unapproved asset
- **Object:** `Workspace.WoodenShip.Prim.Splash`, `Workspace.Boathouse.Prim.Splash`.
- **Evidence:** `SoundId = rbxassetid://167123203`, `Volume = 0`, `Looped = true`,
  `IsPlaying = true` on both. Console: **30 ×** `ContentId: rbxassetid://167123203 failed due to:
  Asset is not approved for the requester` in one edit session.
- **Why it matters:** a permanently playing, permanently inaudible, permanently failing sound. It
  costs an asset retry every ~13 s and floods the console, which hides real warnings during
  playtests. P2 on looks, P1 on tooling (it is why §5 of the inventory is noisy).
- **Direction:** both — stop the loop and drop the volume-0 object from Studio; fix the ID or remove
  the object in the repo.
- **Fix in:** prompt **07** (ship audio) with prompt **05**.

### D-05 · Unattributed asset `203785492`
- **Object:** unknown — **not** any instance property and **not** any of the 81 scripts.
- **Evidence:** 15 × `ContentId: rbxassetid://203785492 failed due to: Asset type does not match
  requested type`; `script_grep` for `203785492` over all scripts → 0 matches; property sweep over
  `SoundId`/`Texture`/`TextureID`/`MeshId`/`Image`/`ColorMap`/`Meta`/`NormalMap`/`RoughnessMap`/
  `EmissiveMap`/sky faces/`CursorIcon` → 0 hits.
- **Why it matters:** unowned console noise; also possibly one of *our* older sound IDs requested as
  the wrong asset type. Cannot be closed until it is attributed.
- **Fix in:** prompt **09** (re-check in Play, where the requester is identified). Blocked: needs one
  more sweep from a live client.

---

## P2 — polish

### D-06 · Duplicate `Gerstner` module inside itself — **FIXED in Studio 2026-10-26**
- **Object:** `ReplicatedStorage.Gerstner.init` (ModuleScript, 341 lines, 11950 bytes).
- **Evidence:** `ReplicatedStorage.Gerstner` (ModuleScript) has 7 children — `Appearance`,
  `HeightLookup`, `Helper`, `Settings`, `Serial`, `Types`, **`init`**. Parent and child have the
  **same source hash `13697039`**. The child matches `src/ReplicatedStorage/Gerstner/init.luau`
  exactly; nothing `require`s `Gerstner.init` (40 `require` sites checked).
- **Why it matters:** ~12 KB of dead replicated source, and a trap: `require(Gerstner.init)` returns
  a *second* module instance with its own state, which would silently desync waves from the real one.
- **Fix in:** prompt **09** (delete the child; read back after).
- **Done:** deleted `ReplicatedStorage.Gerstner.init` from Studio; verified absent; parent source
  unchanged at 11950 bytes.

### D-07 · `FloatingObjectGenerationServer` hardcodes the report interval in Studio — **FIXED in Studio**
- **Object:** `ServerScriptService.FloatingObjectGenerationServer`.
- **Evidence:** Studio reads `local minInterval =  0.1` (with a stray double space) and declares an
  unused `local Config = ReplicatedStorage.FloatingObjectGeneration.FloatingObjectConfig`; repo reads
  `Config.Streaming.CameraMinReportInterval or 0.1`. repo 72 / Studio 73 lines.
- **Why it matters:** the Studio copy ignores a config knob that the repo exposes, so changing
  `CameraMinReportInterval` would do nothing in Studio.
- **Direction:** repo → Studio.
- **Fix in:** prompt **09**.
- **Done:** pushed the repo file to Studio; verified 73 lines and
  `Config.Streaming.CameraMinReportInterval` present.

### D-08 · Fishing rod UI tuning differs between repo and Studio — **FIXED**
- **Object:** `StarterPack.StickFishingRod.FishingConfig` → `Config.Gui`.
- **Evidence:** repo `{Distance = 0.2, Speed = 0.9, Angle = 0}`; Studio
  `{Distance = 0, Speed = 0.35, Angle = 35}`. Both files are 77 lines; only the `Gui` block differs.
- **Why it matters:** `FishingClient.client.luau:48` feeds this straight into
  `FloatingGui.new(gui, Config.Gui)`, so the rod UI sits somewhere different depending on which copy
  runs. The user accepted fishing as "Normal" on the **Studio** values.
- **Direction:** **Studio → repo**, pending the user's word (this one is a taste call, not a bug).
- **Fix in:** prompt **06**.
- **Done:** the user confirmed the Studio values are the ones to keep; commit `856fb63` ported them into
  the repo, both sides read back identical at 80/80 lines.

### D-09 · A debug harness runs a PRECISE wave lookup every frame — **FIXED in Studio**
- **Object:** `Workspace.SingleHeightLookup.LookupTesting` (`Workspace.SingleHeightLookup`, Script, 15 lines).
- **Evidence:** connects `RunService.Stepped` and calls
  `HeightLookup.Lookup(Part.Position, 'PRECISE', …)` every frame, then writes `Part.Position`; a
  second `while true` loop re-reads the zone every 2 s. Never despawns.
- **Why it matters:** a permanent per-frame `PRECISE` lookup (triangle-exact, ~200 reads per lookup
  per ROADMAP 1.2) plus a replicated position write, on the server, for a debug part. Cheap per
  frame but pointless, and it pollutes any ocean performance measurement done in Play.
- **Fix in:** prompt **09** (delete from Studio; it is not in the repo).
- **Done:** deleted `Workspace.SingleHeightLookup.LookupTesting`, verified absent. The parent is a
  `Part` that also carries a `Highlight`; both were left in place because they may be a deliberate
  marker — only the per-frame script was removed.

### D-10 · Zone scripts exist twice
- **Object:** `Workspace.RoughSeaArea.RoughSea` + `ServerStorage.OceanEvents.SeaStuff.RoughSeaArea.RoughSea`
  (19 lines, same source `43676cc2`); `Workspace.Whirlpool.Whirlpool` +
  `ServerStorage.OceanEvents.SeaStuff.Whirlpool.Whirlpool` (41 lines, same source `9bf3cd18`).
- **Evidence:** survey hashes are identical within each pair.
- **Why it matters:** two live copies of the same zone driver. If they both fire, the zone is applied
  twice; if only one is meant to run, the other is dead. Needs a decision, not a deletion, because
  the `OceanEvents` copy may be the spawn template.
- **Fix in:** prompt **04** (zones/seam) — record which one is authoritative first.

### D-11 · Third-party trees live only in Studio
- **Object:** `ReplicatedStorage.UsefulFunctions.Module` (835 lines + 12 UI sub-scripts),
  `Workspace.MODULE.VoxBreaker` (1407) + `PartCache` (192) + `PartCache.Table` (107).
- **Evidence:** not referenced anywhere in `default.project.json`; absent from `src/`.
- **Why it matters:** `validate-project.js` legitimately reports the tree as consistent, but a Rojo
  build would produce a place missing these. Any future "rebuild from repo" loses them silently.
- **Fix in:** prompt **09** — decision needed: vendor them under `src/`, or document them as
  must-not-be-rebuilt.

### D-12 · Three ships are built differently — **REVISED 2026-10-26**
- **Object:** `Workspace.WoodenShip`, `Workspace.Boathouse`, `Workspace.MisoSoup`.
- **Evidence:** only `Boathouse` has an engine `Sound` (`Motor.Engine`, `8916893206`, vol 2); only
  `Boathouse` and `WoodenShip` have a `Splash`; `MisoSoup` has neither. Attributes:
  `MisoSoup Draft -7.3 / SinkRestOffset 2.4`, `WoodenShip Draft 5.5 / SinkRestOffset -2`,
  `Boathouse Draft 3.5` (no `SinkRestOffset`). Part counts: MisoSoup 75, WoodenShip 11, Boathouse 29.
- **Why it matters:** "Boathouse bounces at draft 3.5" (brief) is a tuning bug on a ship whose
  siblings carry a `SinkRestOffset` it lacks. The uneven audio means a fix cannot be copy-pasted
  across all three.
- **Fix in:** prompt **07**.
- **Revising measurement:** the Boathouse is not floating at all — it is parked on `Workspace.Part`
  (slab top `Y = 70.24`), and its server buoyancy is correctly disabled as "airborne". See
  `04-seam-zones.md` §3. "Boathouse bounces at draft 3.5" cannot be reproduced until it is put in
  water. Its dormant `Draft = 3.5` stays as-is.
- **Waterline, measured:** `ServerBoat` (reference) has the sea 1.6 studs below its `Main` top — cut
  like a hull. `WoodenShip` has the sea **3.7 studs above** its `Main` top (sits deep, and is also the
  hull with the stale client, D-01). `MisoSoup` floats with `Main` fully clear (0.85 studs).

### D-13 · `MisoSoup` draft is negative
- **Object:** `Workspace.MisoSoup`, attribute `Draft = -7.3`.
- **Evidence:** above; its siblings are `+5.5` and `+3.5`.
- **Why it matters:** either a deliberate flag (this is the rarest ship) or a sign error. Sign errors
  in draft are exactly the class of bug the "waves colliding" report describes.
- **Fix in:** prompt **07** — confirm intent with the user before changing.
- **2026-10-26:** left unchanged. Its waterline measurement (`Main` clear of the water by 0.85 studs)
  is consistent with a hull that is meant to ride high, but the sign is still unexplained.

### D-17 · Legacy `BodyPosition`/`BodyGyro` left on a hull

- **Object:** `Workspace.Boathouse.Prim.BodyPosition` (target `0, 0, 0`), `Workspace.Boathouse.Prim.BodyGyro`.
- **Evidence:** neither is created by the current handler (see `Handler.server.luau`, which builds
  `UnmannedBuoyancy`/`UnmannedOrientation` instead). A `BodyPosition` whose goal is the world origin
  is a live hazard if anything ever enables it.
- **Why it matters:** inert today, catastrophic if enabled; also confuses the ship script audit.
- **Fix in:** prompt **07** — delete after confirming `Prim` is not needed. `MisoSoup` also has a
  `Prim`; check it too.

---

## P3 — debt

### D-14 · Runtime-created fishing remotes
- **Object:** `src/Workspace/StickFishingRod/FishingServer.server.luau:55,58`.
- **Evidence:** `local fishEvent = remotes:FindFirstChild("FishEvent") or Instance.new("RemoteEvent")`.
- **Why it matters:** the client `WaitForChild`s a remote that only exists once the server script has
  run. Works in practice; a standing order-dependency.
- **Fix in:** prompt **06**.

### D-15 · `find-dead-config` sees 0 keys in `Gerstner/Settings`
- **Object:** `tools/find-dead-config.js` vs `src/ReplicatedStorage/Gerstner/Settings/init.luau`.
- **Evidence:** tool prints "Settings — 0 config keys — no dead keys" while the file defines
  `PERF`, `GRID_SETTINGS`, `DEBUG`, `MeshDetailDistance`, `LowRenderDistance`,
  `MaxChunkRenderDistance`. The module ends with `GerstnerWave:SET_SETTINGS(…)` and starts with
  `require(script.Parent)`, so it is not a plain table the scanner recognises.
- **Why it matters:** "no dead keys" is a **false pass** for the one file whose dead keys matter most
  (the ocean knobs). Do not cite this check as coverage for `Settings`.
- **Fix in:** prompt **09** (tooling), document-only until then.

### D-16 · `check-syntax.js` false-fails without `.tools/`
- **Object:** `tools/check-syntax.js` fallback path.
- **Evidence:** with `.tools/bin/luau-compile` absent, 3 files fail: `SwimClient` `[324:17]`,
  `AmbientSea` `[135:16]`, `ParallelWorker` `[76:14]`. All three compile clean under
  `luau-compile` 0.736. Causes: Luau `if-then` expressions and a nested table type
  `{ [Vector3]: { number } }`.
- **Why it matters:** a clean checkout reports "3 file(s) failed" and contradicts the documented
  baseline of 23 — which invites someone to "fix" valid Luau.
- **Fix in:** prompt **09** — make the fallback skip (not fail) on Luau-only syntax, or fail loudly
  with "install `.tools/`".

---

## P0 — to be established by prompt 02

The brief's two live complaints — **visual spasms in rough/transitional seas** and **"waves
colliding"** — are not yet defects I can name with evidence. The audit only establishes the ground
truth they must be measured against:

- `FAR_WRITE_EVERY = 3` and `UV_WRITE_EVERY = 3` are live (`Settings/init.luau:164,165`, consumed
  at `ParallelWorker.client.luau:104,105`), so far vertices are written every 3rd frame while near
  vertices are written every frame — the S1 suspect in prompt 02 is **present and armed**, not
  hypothetical.
- The mesh draws `rest + D(rest)` while physics reads `PLANE_Y + D(point).Y` at the rest point
  (`WaveFloat.HeightAt`); there is no inverse mapping, so S2 (rest-vs-displaced) is **structural**,
  not a regression.
- `Workspace.Ocean` is empty in edit mode, so both must be measured in Play.

**Nothing here is called a defect until prompt 02 measures it.** And per the brief, I need the
user's clip or screenshot before concluding what "colliding" means.

---

## Summary

| Severity | Count | IDs |
|---|---|---|
| P0 | 0 established (2 suspects armed) | — |
| P1 | 5 | D-01, D-02, D-03, D-04, D-05 |
| P2 | 8 | D-06 … D-13 |
| P3 | 3 | D-14, D-15, D-16 |
| **Total** | **16** | |

Highest-value fix by consequence: **D-01** — it is the only mechanical explanation on record for one
of the named ship bugs, and it is a single file push in the repo → Studio direction.

---

## Requirements captured from the user (2026-10-26 session)

Asked directly during this pass. These are product requirements, not defects, and they change what
prompts 06/07 should do:

1. **"All of the above"** for the collision symptoms — the user confirmed all four of: objects
   hovering/sinking through the water, waves visually intersecting, water punching through hulls,
   and tearing/stepping at a distance. S2 covers hover/sink, S1 covers distant stepping. Waves
   intersecting each other and water through a hull are **not yet explained** and stay open.
2. **Vertex jitter and ocean performance are the priority** for the next pass.
3. **Per-ship speed and steering settings.** "Each ship must have their own settings for speed and
   steering etc." Today `Ship/Client.client.luau` and `Ship/Handler.server.luau` are a single
   template deployed to all three ships, so all three share one tuning. This is a **new
   requirement** for prompt 07, not a bug — and it interacts with D-01 (WoodenShip still runs an
   older copy of that shared client), so D-01 should be fixed *before* the per-ship split, or the
   split will be applied to a stale baseline.
4. **Not every ship has a sail.** `ShipDrive` currently assumes a rig; the drive must tolerate a
   ship with no `Sail` part. Relevant to prompt 07 together with D-12 (the three ships are already
   built differently: only Boathouse has an engine sound, only two have a Splash).
5. **Studio values are authoritative for tuning** where repo and Studio disagree on a taste value
   (applied to D-08).


---

## Parity state at the end of this pass

Re-surveyed the live place after every Studio change. Current state:

| | before | now |
|---|---|---|
| scripts in the place | 81 | **79** (2 duplicates/debug scripts deleted) |
| repo files with a Studio counterpart | 41 -> 45 instances | 41 -> 45 instances |
| ...that match byte-for-byte | 41 / 45 | **45 / 45** |
| ...that differ | 4 | **0** |

So the repo and the live place now agree completely on every script that exists in both.

Remaining known *drift in content* (not script text): the Studio-only trees listed in
`01-inventory.md` §2 (`UsefulFunctions`, `VoxBreaker`, the premade island payloads, the duplicated
zone scripts D-10) still exist only in the place and would be lost by a rebuild from the repo. That
is D-11 and it needs a decision, not a fix.

### D-05 addendum (2026-10-26): asset `203785492` closed as **unattributable**

The stray asset ID recorded in D-05 was hunted across the whole DataModel, three ways:

| Method | Coverage | Result |
|---|---|---|
| String-property sweep, first pass | every string prop incl. `AnimationId`, `Texture`, `SoundId`, `Image`, `MeshId`, colour maps, skybox | 0 hits |
| **`Content`-property sweep** (new this pass) | `MeshContent`, `TextureContent`, `ColorMapContent`, `NormalMapContent`, `RoughnessMapContent`, `MetalnessMapContent`, `EmissiveMaskContent`, `AudioContent` — **452 populated properties** over `workspace`, `ReplicatedStorage`, `ServerStorage`, `ServerScriptService`, `StarterPack`, `StarterPlayer` | **0 hits** |
| Script source | all 79 `.luau` files under `src/` | 0 hits |
| `Animation` objects | ID compare on every `Animation` in the DataModel | no match |

The Content sweep mattered: the first pass only read `.Texture`-style *string* properties, and the
modern mesh/editable-mesh API stores the same IDs as **Content** values. So the prior "not found"
result had a real gap. It is now closed — the ID is in no populated property of any type anywhere in
the DataModel.

**Conclusion:** `203785492` is not attributable by inspection. It can only be found at join time, with
either a `ContentProvider:PreloadAsync` request log or a `ContentProvider.RequestQueueSize` trace.
That is a targeted runtime job, not a grep. **Closed as won't-fix by inspection**; downgraded from
D-05's original severity because nothing in the place references it, so it cannot currently be
rendering or playing.


### D-17 (2026-10-26): **FIXED** — and it was live, not inert

The Boathouse's four legacy constraints were removed from the place. Measured before removal:
`Prim.BodyPosition` `Position (0,0,0)` with `MaxForce (0, 400000, 0)` (no `Enabled` property — parented
means on) is a permanent 400 000 Y-force pulling the hull toward world Y = 0, about 74 % of the hull's
own weight; `Prim.BodyGyro` holds upright with 200 000 X/Z torque against the wave pose;
`Motor.Steer` is a `BodyAngularVelocity` at 0 rad/s with 2 011 493 Y torque, a steering lock;
`Motor.VectorForce` is zero-force junk. No script references any of them. All three hulls now report
`movers=0`; `ServerBoat` keeps its three and is untouched. See `07-ships.md` §2.

### D-18 (new, **FIXED**): the buoyancy servo goal was in the wrong frame

`WaveFloat.Solve` returns a **hull-centre** height, but `Ship.Handler` and `Ship.Client` wrote it into
`AlignPosition.Position`, which in `OneAttachment` mode is a goal for the attachment on the
`VehicleSeat`. On `WoodenShip` that put the goal 16.9 studs too low, so the servo saturated and held a
steady **15.1-stud** error, and the anti-sink guard fought it. Fixed by converting into the mover's
frame (`goal = here.Y + ((targetY - draft) - Main.Center.WorldPosition.Y)`); the error drops to 3.1 and
the settled hull moves from offset −3.74 to +0.97. Guard reference default corrected the same way. This
is why the per-hull `Draft` values looked arbitrary: they were compensating for a 15–17 stud frame
error, not setting a waterline. See `07-ships.md` §3.

### D-19 (new, recorded, **not** fixed): ship handling was one profile for the whole fleet

Every hull read `ShipDrive.Defaults`, so the 125-stud, 19 565-mass `MisoSoup` handled exactly like a
45-stud sloop. `ShipDrive.Resolve(ship)` now reads per-hull number attributes (and `ShipDrive.TopSpeed`
exists for the docs/harness), with values set in Studio for the three hulls: top speeds 26.0 / 18.0 /
13.9 studs/s and turn radii 113 / 163 / 58 studs against the reference's 29.1 / 58.2. See
`07-ships.md` §4.


### D-20 (new, 2026-10-27, **FIXED**): the floating-object system never started

`ServerScriptService.FloatingObjectGenerationServer:45` read `Config.Streaming.CameraMinReportInterval`
where `Config` was never defined in that file (the script required `FloatingObjectGenerator`, which
returns functions only). The top-level error (`attempt to index nil with 'Streaming'`) killed the script
before the `task.spawn(Generate())` at its bottom, so **no floating object has been generated or streamed
for as long as that line has been broken**: `rendered=0, streamed=false, SpawnAttempts=0`. Fixed by
requiring `FloatingObjectConfig`. After the fix: 35 spawns, 23 rendered, 74 cached records, `streaming=true`.
See `08-floating.md` §3.

### D-21 (new, 2026-10-27, **FIXED**): frozen props seated by pivot instead of box centre

`spawnRecord` computed a *box-centre* float height and applied it to `model:PivotTo`, but `GetPivot` is
whatever the modeller left — up to 1.5 studs off the box centre and in a different direction per template
(Small `PlankDebris` −0.89, Medium `Lifeboat` +0.68). Measured: Small asking 0.6 rode 0.847 of its height
above water, Medium asking 0.6 rode 0.392. That is why `FloatRatio` "did not work". The buoyant path
already drove the box centre, so the two paths also disagreed. Fixed by rotating about the box centre and
then translating it onto the float height. After: Small 0.713 and Medium 0.608 for a 0.70 ask. See
`08-floating.md` §4.

### D-22 (new, 2026-10-27, **HARDENED**): the sight rule held by exactly zero margin

`Streaming.CacheDistance` and `Streaming.CameraMaxDistance` were both 900. The far branch of
`recordHasInterest` caches anything beyond `CacheDistance` with no sight test, which is only safe while
`CacheDistance >= CameraMaxDistance`. Added a guarded camera check that runs only if the two cross, so the
invariant cannot be broken by a config edit. Zero cost today. See `08-floating.md` §6.

### D-23 (new, recorded, **not** changed): no rendered prop is ever in the near band

`Buoyancy.NearDistance` is 150 but `Streaming.MinPlayerDistance` is 200, so nothing may render closer than
200 studs and no rendered prop can enter the fast-cadence band; every prop runs `SoftResponsiveness` 8 at
`UpdateInterval` 0.12 while the ship runs `Responsiveness` 12 every frame. This is the likeliest reason
props track the waves more loosely than the ship. A taste/perf trade — recorded for the user, not changed.


## Triage (prompt 09, 2026-10-27)

Every entry has a status. `Fixed` names the commit; `wont-fix` gives the reason; `open` names the owner.

| # | Sev | Item | Status |
|---|---|---|---|
| D-01 | P1 | `WoodenShip` ran a stale client | **fixed** `a4ef9a0` (Studio copy replaced, parity hash matches) |
| D-02 | P1 | `IslandConfig` older in Studio | **fixed** `1cb64e2` + Studio, hash match |
| D-03 | P1 | silent island rise/sink audio | **fixed** `1cb64e2` |
| D-04 | P1 | two muted looping `Splash` sounds on an unapproved asset | **fixed** 2026-10-27, Studio-only (see below) |
| D-05 | P2 | unattributed asset `203785492` | **wont-fix** — not in any property or script of any type; seen at runtime, needs a `ContentProvider` trace |
| D-06 | P2 | duplicate `Gerstner` inside itself | **fixed** `cb1adbd` (deleted in Studio) |
| D-07 | P2 | server hardcodes the camera report interval | **fixed** `5230580` (the missing `Config` require; the interval is read from config) |
| D-08 | P2 | fishing rod UI tuning differs | **fixed** `856fb63` |
| D-09 | P2 | a debug harness ran a PRECISE lookup every frame | **fixed** `cb1adbd` |
| D-10 | P2 | duplicate zone scripts | **wont-fix** — both exist and both print, but `GetZoneParameters` returns one node per position, so only one answer and one print ever appears. Measured, harmless. |
| D-11 | P2 | third-party trees live only in Studio | **open** — content work, needs the user's models; not code |
| D-12 | P2 | three ships built differently | **closed as not-a-defect** — the Boathouse is parked on `Workspace.Part`, not broken (`04`) |
| D-13 | P2 | `MisoSoup` draft is negative | **fixed as a symptom** — the drafts were compensating for D-18's 16-stud frame error; `Draft` is now a 1:1 lever and the remaining value is a taste call |
| D-14 | P3 | fishing remotes created at runtime | **wont-fix** — self-healing (`FindFirstChild … or Instance.new`) and both remotes are live; changing it is a fishing rewrite |
| D-15 | P3 | `find-dead-config` sees 0 keys in `Gerstner/Settings` | **open** — tooling debt, does not affect the game |
| D-16 | P3 | `check-syntax.js` false-fails without `.tools/` | **wont-fix** as a code change; documented in `10-continue.md` (run `tools/setup-tools.sh`). The three "failures" are the false ones. |
| D-17 | P1 | legacy `BodyPosition`/`BodyGyro` on a hull | **fixed** `a1b2685` (all four movers removed; they were live) |
| D-18 | P0 | servo goal in the wrong frame | **fixed** `a1b2685` |
| D-19 | P1 | one handling profile for the whole fleet | **fixed** `a1b2685` |
| D-20 | P0 | floating objects never generated | **fixed** `5230580` |
| D-21 | P1 | frozen props seated by pivot | **fixed** `5230580` |
| D-22 | P3 | sight rule held by exactly zero margin | **hardened** `5230580` |
| D-23 | P2 | no rendered prop is ever in the near band | **open** — owner: the user (taste vs perf, see `08-floating.md` §7) |

### D-04 detail (2026-10-27)

`WoodenShip.Prim.Splash` and `Boathouse.Prim.Splash` were both `SoundId = rbxassetid://167123203`,
`Volume = 0`, `Looped = true`, `Playing = true`. The asset is not approved for the requester, so it could
never be heard; the only effect was the console spam and a pointless loop. No script references either
instance (`script_grep "Splash"` finds only the DiveSplash client and the fishing bobber). Both are now
`Looped = false`, `Playing = false`, read back. The objects themselves are kept — they are content, not
code, and deleting a user's instances is not a polish decision.

Note for anyone reading the console: the ID is **still** requested once at join. That is the engine
preloading every `Sound` in the place, not our loop, so it is not a regression signal. Clearing the
`SoundId` on the two dead instances would remove it entirely; left as the user's call.
