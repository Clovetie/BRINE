# 08 — Floating objects and islands

Play measurements and fixes. The headline is that **the floating-object system was not running at
all**: `FloatingObjectGenerationServer` threw on line 45 before it ever scheduled `Generate()`, so the
sea has been empty of props for however long that line has been broken.

---

## 1. A1 — repo ↔ Studio parity: **PASS**, 39/39

Re-surveyed the place and compared by content hash
(`tools/studio-probes/bridge/parity_hash.py`, which reads the plugin's own FNV-1a). Every floating and
island module was added to the manifest for this prompt:

| Pair | Result |
|---|---|
| `FloatingObjectGeneration.FloatingObjectGenerator` | match (`1413f9db` → later `edac6208` after §3) |
| `FloatingObjectGeneration.FloatingObjectConfig` | match (`16e456fe` → `…` after §5) |
| `FloatingObjectGeneration.WaveFloat` | match (`d0158f0d`) |
| `IslandGeneration.Density` | match (`159cfb5b`) |
| `IslandGeneration.Discovery` | match (`76565671`) |
| `IslandGeneration.Placement` | match (`ef859b39`) |
| `IslandGeneration.Presentation` | match (`690de8a7`) |
| `IslandGeneration.Proximity` | match (`ca3920d5`) |
| `IslandGeneration.IslandGenerator` | match (`4071d619`) |
| `IslandGeneration.IslandConfig` | match (`2bf3446b`) |
| `ServerScriptService.FloatingObjectGenerationServer` | match (`24a40885` → `8c9bd380` after §2) |
| `StarterPlayerScripts.FloatingObjectsClient` | match (trailing newline only) |

**39 pairs, 39 match, 0 differ, 0 missing.** The six Studio-first edits the prompt worried about
(`Density`, `Placement`, `IslandGenerator`, `IslandConfig`, `FloatingObjectConfig`,
`FloatingObjectGenerator`) are all already in the repo; there is no drift in either direction.

## 2. A2 — no debug hooks: **PASS**

`script_grep` over all **79** scripts for `args_gen_dbg` → **0 matches**. The two hooks the prompt named
(`args_gen_dbg_on` 30ef92c1, `args_gen_dbg_fix` 62503b5c) are gone from both sides, and the repo grep is
clean too. Also swept every instance attribute in `ReplicatedStorage`, `ServerStorage`, `Workspace`,
`StarterPlayer` and `ServerScriptService`: **32 attributes, 0** with `dbg`/`debug` in the name.

One name the prompt flags as a leftover is *not* a hook: `SoftResponsiveness` is a real, used config knob
(`FloatingObjectConfig:337`, read at `FloatingObjectGenerator:821` and `:1257`). Its value is **8**, not
the 24 the notes mention, so it was already reverted.

---

## 3. D-20 (new, critical, **FIXED**): the floating-object system never started

Console, first Play of this session:

```
ServerScriptService.FloatingObjectGenerationServer:45: attempt to index nil with 'Streaming'
```

Line 45 is `local minInterval = Config.Streaming.CameraMinReportInterval or 0.1`. `Config` was **never
defined in that file** — the script requires `FloatingObjectGenerator` (which returns functions only) and
then references a `Config` that does not exist in its scope. The error is thrown at the top level, so the
`task.spawn(function() FloatingObjectGenerator.Generate() end)` at the bottom **never ran**.

Measured before the fix, in Play with a player spawned:

```
rendered=0  cachedRecords=0  buoyant=0  frozen=0  streaming=false  freshCameras=0
diagnostics: ActivationAttempts=0 SpawnAttempts=0 SpawnedTotal=0 ... (all zero)
tagged in workspace=0
```

The catalog itself was fine (`Small` 2 templates, `Medium` 1, `Large` 1, tags intact), so this was purely
the missing require. Fixed:

```lua
local Config = require(folder:WaitForChild("FloatingObjectConfig"))
```

After the fix, same probe:

```
rendered=23  cachedRecords=74  buoyant=0  frozen=23  streaming=true  freshCameras=1
diagnostics: SpawnAttempts=35 SpawnedTotal=35
cacheReasons: Unseen=12
```

So every symptom in this prompt's "current state" that was measured against a *live population*
(density, nearest ring, float ratios, frozen-vs-buoyant counts) was measured on a population that no
longer existed. They are not wrong, they are historical.

This also revises the prompt's note 4 ("the line 75 crash was fixed, do not revert it"). The catalog-side
crash was fixed; the server-side script still had its own fatal nil four lines earlier in impact.

---

## 4. D-21 (new, **FIXED**): frozen props were seated by pivot, not by their box centre

`spawnRecord` computed the float height as `surfaceY + height·(ratio − 0.5)` — a formula about the
**bounding-box centre** — and then applied it to `model:PivotTo(CFrame.new(x, pivotY, z) …)`. `GetPivot`
is wherever the modeller left the pivot, which on these templates is up to 1.5 studs from the box centre
and **in a different direction per template**.

Measured at spawn, before the fix (`PlaceOne` at a known ratio, read one frame later):

| Class | `FloatRatio` asked | pivot offset | `above` fraction measured |
|---|---|---|---|
| Small (`PlankDebris`) | 0.60 | −0.89 | **0.847** |
| Small (`Raft`) | 0.60 | −1.45 | 0.62 |
| Medium (`Lifeboat`) | 0.60 | +0.68 | **0.392** |
| Large (`Container`) | 0.35 | 0.00 | 0.30 |

Two props of the same class rode at different heights whatever the config said — which is exactly why
`FloatRatio` "did not work" for the user. The buoyant path never had this bug: its mover attachment is
placed at `bboxCFrame`, i.e. the box centre, so the two paths disagreed with each other too.

Fix: rotate about the box centre, then translate the box centre onto the float height (translation only,
so the rotation is preserved). After the fix, six fresh placements all inside the aimed view:

| Class | asked | measured `above` |
|---|---|---|
| Small | 0.70 | 0.617, 0.728, 0.794 (mean **0.713**) |
| Medium | 0.70 | 0.597, 0.535, 0.691 (mean **0.608**) |

The residual is wave phase: the sample point travels with the prop, and the analytic height is read a
fraction of a second after seating. Medium's −0.09 bias is one template (`Lifeboat`, 5.51 tall).

---

## 5. Requirement 3 — "Small and Medium float too low": raised 0.6 → 0.7

`FloatingObjectConfig.Classes.Small.FloatRatio` and `.Medium.FloatRatio` are now **0.7** (were 0.6).
Read back live in Play: `live cfg: Small=0.7 Medium=0.7`, and the six fresh placements above track it.
`Large` (0.35) and `Debris` (0.4) are unchanged. This is the first time the knob has had a measurable,
coherent effect, because of §4.

Per A4, the target is the user's to set — the numbers above now let them: each 0.1 of `FloatRatio` is
0.1 × the prop's own height, and heights are 2.8 (PlankDebris), 3.9 (Raft), 5.5 (Lifeboat), 29.0
(Container).

---

## 6. A3 — no despawn in sight: **PASS** on all three paths

Method. Armed the three paths so each would fire quickly — `Despawn.MinLifetime/MaxLifetime = 5/7`
(instead of 1800/2700), `Streaming.OutOfViewGrace = 1.5` (instead of 3), `Despawn.CullCooldown = 1` —
called `ClearGenerated()` then `Generate()` so the fresh population carried the short lifetime, aimed the
camera at the props through `SetCameraState` (the same entry point the client's `CameraReport` uses),
re-aiming every 0.4 s, and tracked the identity of the props that were in view when the window opened.

```
regenerated, lifetime 5-7s
tracked set: 10 props in view
A in-sight 18s (2.5x max lifetime): 0 of 10 tracked props vanished -> PASS
cache reasons during the window: Clear=24 Lifetime=9 RenderLimit=23 Unseen=206
```

18 seconds is 2.5× the maximum lifetime and 12× the grace timer, and during that same window the cull
machinery was demonstrably working — it removed 206 Unseen, 23 RenderLimit and 9 Lifetime records. **None
of them was a prop the camera was on.**

The control run (camera turned 180° away, same population, 10 s) removed **51 of 60** props, so the test
has discriminating power: with the camera off them they are culled promptly, with it on them nothing goes.

Two structural notes recorded from reading the code:

* The **lifetime** path defers an in-sight object by `expiresAt = now + 10` and re-checks
  (`FloatingObjectGenerator:1934`), so an object being watched never expires.
* The **render-cap** path (`getCullCandidate`) skips anything `isInSight`, and `isInSight` is
  camera-cone **or** inside the prop's own `SimDistance` band. So the sim band is itself a protection
  radius, not just a physics radius.
* The **Unseen** path uses `recordHasInterest` → the camera cone with a grace timer, and only for
  rendered objects; unrendered ones are protected by `MinPlayerDistance`.

### One real hole, closed defensively (D-22)

`Streaming.CacheDistance` and `Streaming.CameraMaxDistance` are **both 900**. The far branch of
`recordHasInterest` returns "cache it" for anything beyond `CacheDistance` *without any sight test*, which
is only safe while `CacheDistance ≥ CameraMaxDistance`. Today those are equal, so the margin is exactly
zero: raising `CameraMaxDistance` (or lowering `CacheDistance`) by one stud would create a band of visible
but cullable objects. Added a guarded check that only runs when the two cross:

```lua
if nearestSq > cacheDistance * cacheDistance then
    if record.rendered
        and (streamingConfig.CameraMaxDistance or 800) > cacheDistance
        and isSeenByAnyCamera(pos, now, 15) then
        record.unseenSince = nil
        return true, true
    end
    return false, false
end
```

Zero cost at today's values, and the invariant can no longer be broken by a config edit.

---

## 7. Task 4 — density, re-measured on a live population

23 props rendered around one player at the spawn area:

| Ring (studs from player) | Props |
|---|---|
| 0–200 | **0** (`MinPlayerDistance` = 200, working) |
| 200–400 | 3 |
| 400–600 | 7 |
| 600–900 | 13 |
| 900–2200 | 0 (`CacheDistance` = 900) |

Nearest-neighbour spacing across the 23: **mean 141.7, median 166.6, min 27.2, max 297.1** studs.
By class: Small 15, Large 5, Medium 3. `cachedRecords` = 73.

The prompt's old figures (mean density 0.47, "nearest ring or range value 207.3 studs") cannot be
compared: that population was the ghost of a system whose server script had stopped, and the measured
nearest-neighbour mean here (141.7) is below the never-render ring (200) because the two planes — 200
from the player and 27 between neighbours — are different constraints.

`NearBandStuds` = 150 vs `MinPlayerDistance` = 200 is the awkward pair: the nearest a prop may render is
200 studs, but "near band" (the fast buoyancy cadence) only reaches 150, so **no rendered prop is ever in
the near band** except one that drifts inward. Every rendered prop therefore runs the soft/staggered
cadence (`SoftResponsiveness` 8, `UpdateInterval` 0.12). That is very likely why the props look like they
are not tracking the waves as tightly as the ship does — the ship uses `Responsiveness` 12 every frame.
Recorded, **not changed**: it is a taste/perf trade the user should decide, and the alternative (lower
`MinPlayerDistance`) changes what the sea looks like close to the boat.

## 8. A5 — smoke suite: **PASS**, 83 passed / 0 failed

Run after every change in this pass (`node tools/smoke-test.js`). `luau-compile` clean on the generator,
`check-syntax` 23/23. The generator changes were written to stay inside what the Fengari mock supports:
`CFrame + Vector3` is valid Roblox but absent from the mock, so the seating fix uses CFrame composition
instead.

## 9. D-05, finally seen in the wild

The console during Play prints

```
ContentId: rbxassetid://203785492 failed due to: Asset type does not match requested type
```

so the asset *is* requested at runtime. It still resolves to no property or script (previous pass: 452
`Content`-typed properties, all string properties, all 79 scripts — zero hits). It is most likely loaded by
`applyAutoMeshCollision`/insert-asset code paths inside the plugin ecosystem rather than by the game. No
action; still needs a `ContentProvider:PreloadAsync` trace at join to name it.

## 10. What to try in Play

1. **The sea should have props in it now.** Before this pass it had none at all. Look for 20-ish props in
   the 200–900 stud ring; nothing closer than 200 studs.
2. **Small and Medium should ride noticeably higher** (0.7 of their own height above water instead of the
   mixed 0.39–0.85 they were getting). Say if 0.7 is still too low or now too high — it is one number per
   class in `FloatingObjectConfig.Classes`.
3. **Watch a prop for a minute.** It should never blink out while you are looking at it; turning away
   should let it go.
4. Islands were not changed in this pass (they were already at parity and the density/rings above are
   about floating objects).

## 11. Not verified

* **Buoyant props were measured only once** end-to-end (a `Raft`: `above` 0.274 rising to 0.406 while
  the player stood in its sim band). Detailed response of the buoyant path — how fast it settles, whether
  it overshoots — was not swept, because `PlaceOne` near the player is blocked by `MinPlayerDistance`
  and the local probe budget is ~18–45 s.
* **Island density/rings** (prompt requirements 1 and 2 as they apply to islands) were not re-measured:
  `IslandGenerator` is at parity and the user's complaint in this prompt is about floating objects.
* **The near-band/tuning question in §7** is recorded, not decided.


---

## The frozen band was hanging in the air (found and fixed 2026-10-27)

Prompt 08 ended with the float system working for *buoyant* props. Nobody had looked at the
**frozen** ones, which is most of them: at spawn all **23** rendered props reported
`FloatingState = Frozen`, i.e. anchored in place, because `SimDistance` is 170–300 studs while
props render out to ~900. Freezing is deliberate LOD — zero physics, no replication — but the
sea keeps moving under an anchored prop, and it is still visible for hundreds of studs.

Measured over 6 s with the surface moving 2–6 studs, sampling the eight nearest frozen props:

| | before | after |
| --- | --- | --- |
| prop's own vertical span | **0.00 studs, every prop** | matches the surface within 0.1–0.25 |
| worst offender | a `Lifeboat` centred **3.60 studs above** the water; a `Container` **5.93 under** it | rafts track 3.03 vs 2.95, 5.34 vs 5.35, 2.80 vs 2.81 |
| offset swing as waves pass | up to **7.2 studs** | follows the same motion as the water |

So a player looking out saw boats hovering in the air and cargo sunk out of sight, with the gap
breathing by several studs as waves went by. That is a bigger visual error than the ship bounce
the user reported, and it was invisible to every earlier measurement because every earlier
measurement was taken within `SimDistance` of the player.

The fix is deliberately cheap: a frozen prop keeps the pose it had when it froze (that pose was
correct — it was either seated by `spawnRecord` or buoyant a moment earlier) and follows the
surface from there. **One `HeightAt` and at most one `PivotTo` per visit**, on a slow clock
(`FrozenUpdateInterval` 0.35 s) with its own per-frame budget (`MaxFrozenUpdatesPerFrame` 6). No
constraints, no solver, no physics — the whole point of the frozen band is that it costs nothing.

Two mistakes on the way, both caught by measurement:

* **First version set the hull centre to `WaveFloat.Solve`'s target** and moved the model by the
  difference. An **anchored assembly's `AssemblyCenterOfMass` does not refresh**, so every visit
  re-applied an error against a stale value and props walked away from the water — one
  `Container` swung 17 studs. A stored reference pose cannot drift; that is what it does now.
* **Sampling at `record.centerPos`** — the cell position, not the prop's — put the prop on a
  different part of the wave than the one it was floating in, because these waves are only
  25–58 studs long. Measured: a prop moved 0.96 studs while the water under it moved 8.06.
  Sampling at the model's own pivot fixed the remaining lag.

Known limitation, left as is: a prop that was *already* misplaced when it froze keeps that
placement, because the reference is captured at freeze time. It follows the sea correctly, just
from the wrong height. Fixing that means deciding what a frozen prop's float height should be
without its hull sim, which is a bigger question than this pass.

**What is still by design:** props are frozen beyond their `SimDistance` (170–300) while visible
to ~900. They now move with the water, but a player 400 studs away sees a raft riding the swell
without the tilt and lean a buoyant one would have. Raising `SimDistance` trades server CPU for
that fidelity; not changed here, because the LOD budgets were measured deliberately.
