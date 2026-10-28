# 11 — The worker pass: fable's review, verified item by item, and what it changed

The ocean system was sent out as a single-file bundle (`BRINE-ocean-system.txt`, commit `08c871b`)
and came back with a review of the three runtime files: `ParallelWorker` (10), `init.client` (9) and
`WaveFloat` (11). This document is the audit of that review — every claim checked against the code
and, where possible, against the live mesh — plus what was implemented, what was measured, and what
could not be measured.

Everything below is on branch `arena/ocean-sound-and-audit`. The Studio place holds the same code:
`parity_hash` **40/41** with the only difference being `StarterPack.StickFishingRod.FishingConfig`,
which is the user's own Studio tuning (`Gui.Distance 0.45`, `Gui.Angle 25` vs the repo's `0`, `35`)
and is deliberately not overwritten.

---

## 1. Verdicts

Legend: **CONFIRMED** = the defect is real as described; **CONFIRMED, WIDER** = real and the
consequence is larger than the review said; **CORRECTED** = right symptom, wrong mechanism;
**ACCEPTED** = implemented as proposed; **LEFT** = discussed, deliberately not changed.

### File 10 — ParallelWorker

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| W1 | Stale far-band colour: `Info.CurrentColor` advances on skipped frames, so a vertex that crosses into the flat-colour band never gets its colour written | **CONFIRMED, WIDER** | Two failure directions, not one: (a) the colour was written late *and* (b) a vertex that crossed back could keep the flat colour, because both `Info.*` fields advanced as if a write had happened. And the per-frame `Helper.GetVertexColor` call was made for skipped frames too, so up to `WriteEvery-1` of every N colour computations were thrown away. All three are fixed by moving the compute *and* the cache advance inside the gate. |
| W2 | `UpdateChunk` replaces the worker's entry and resets `Rendering`, forcing the snap branch (pop) | **CONFIRMED** | `ChunkInfo[Position] = Data` in the worker, and the main thread's copy always has `Rendering = false`. Merged field-by-field now; the main thread sends tags only. |
| W3 | `print('VERTEX COUNT')` is unconditional | **CONFIRMED** | Also printed the chunk count. Both now behind `Settings.DEBUG`. |
| W4 | Dead `FOV` listener | **CONFIRMED** | `FOV` assigned, never read. Removed with the `Camera` require that fed it. |
| W5 | A 6-slot table per written vertex per frame; `table.create(VertexCount + 1)` buys nothing | **ACCEPTED** | Structure-of-arrays implemented: a reused `OutIds` list plus per-attribute tables keyed by vertex id, consumed and cleared by the serial pass. Also removed the per-vertex `Dampening += Vector3.new(0, -0.85, 0)` allocation (a hoisted `SHORE_DAMP` multiply). |
| W6 | UV and shore transparency computed every frame but used only on write frames | **CONFIRMED, CORRECTED** | The UV cadence is `UV_EVERY` (6), *not* `WriteEvery` — the review's premise that it was "written at most every WriteEvery frames" is only true when `WriteEvery` is 1. Both are now computed only on frames that write them. Shore transparency is additionally cached per vertex and refreshed on the plane's snap epoch, since it is a function of world position only; with `DEPTH_ENABLED = false` it is the constant 1, so the cache removes a call and a SharedTable read per vertex per frame for nothing. |
| W7 | Quantise the colour so identical colours are not rewritten | **ACCEPTED** | 64 bands over the 4.7317-stud envelope = 0.074 studs of height, i.e. 1/64 of the TROUGH→CREST ramp ≈ 1.6/255 per channel. Two corrections to the proposal: (a) a shore-alpha change must also force the write (the review had it in the skip condition but not in the state), and (b) whirlpool vertices are exempt — their darkening comes from the vortex offset, which does not quantise to wave height. The bucket encoding keeps graded buckets **even** and the flat-band sentinel **odd**, so the RoughSea zone (amplitude ×2.5, height beyond the envelope) cannot collide with it. |
| W8 | Replace `WriteCount` with per-attribute counters | **ACCEPTED, and it immediately paid** | The report line is now `pos= color= alpha= uv=` per frame. `alpha=0` in every session because `DEPTH_ENABLED` is false, which is itself the correct reading. |
| VM | Send arrays of pairs instead of `Vector3`-keyed tables | **ACCEPTED** (contract change) | `Compute(waves, Plane, EditableMesh, ChunkList, VertexList)`. The regex parse is gone, each worker receives **only its own** 193-chunk grid instead of all of it (six times over), and the latent `%-?%d+` non-match on a non-integer coordinate went with it. `UpdateChunk(Offset, {ISLAND, ZONE})` is now a partial tag update. |
| Cost | ~0.9 µs per API call | **CONFIRMED** | Measured 0.90–0.94 µs per position write, and serial ms/write was identical between the two build variants, which is the strongest evidence that serial time is purely a call count. |
| Tier | `FAR_WRITE_EVERY_BEYOND = 3` is safe, keep 2 and expose 3 | **ACCEPTED** | Documented in `Settings.PERF` with both measured steps (2 → 0.056 studs mean / 0.109 max; 3 → 0.084 / 0.16). Default stays 2. |
| Balance | Sort chunk offsets by distance before round-robin | **ACCEPTED, effect unmeasured** | Implemented (and the assignment is now deterministic: 33/32/32/32/32/32 chunks, 472/447/439/410/402/391 vertices). The parallel-time spread it was meant to fix could not be isolated from the viewport effect in §3, so no claim is made. |

### File 9 — init.client

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| M1 | Chunk tags are applied against the pre-move plane position | **CONFIRMED** | `UpdateIslands()`/`UpdateZones()` ran before `Plane.Position = ObjectPosition`, and both measure chunks as `Plane.Position + ChunkOffset`, so every retag was one snap stale (up to the 0.25 s loop period). Plane move and secondary tiles now happen first. |
| M2 | Retag messages carry the whole entry | **CONFIRMED** | Now `{ISLAND, ZONE}` only, and only when the tag actually changed (identity compared), so an idle grid stops sending anything at all. |
| M3 | Unused locals; `LERP_MAX_FRAMES` is defined twice and belongs in Settings | **CONFIRMED** | `AssetService`, `clamp`, `Y_AXIS`, `v3zero`, `v3one` and the dead `LERP_MAX_FRAMES` dropped from the main thread; the constant now lives in `Settings.LERP_MAX_FRAMES` and the worker reads it. |
| M4 | `GRID_AREA` overshoots the plane | **LEFT** | Works (a kd-tree query with a generous radius), no runtime cost worth a risky edit. |

### File 11 — WaveFloat

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| P1 | Shore dampening is applied by the mesh but not by physics (R8 break) | **CONFIRMED, currently latent** | The mesh multiplies a near-shore vertex's position by `(1, 0.15, 1)` in both LOD paths; `HeightAt` never did. **But** `DEPTH_ENABLED = false` in the shipped config means `GetVertexTransparency` returns 1 and the mesh never applies it either — so today both sides agree at full amplitude and the bug would appear the moment depth shading was switched on. Fixed anyway, and both sides now read one constant (`Helper.SHORE_HEIGHT_FACTOR`). Physics scales only the *displacement* toward the waterline, not `PLANE_Y`. |
| P2 | `source == "MESH"` with no zone indexes nil | **CONFIRMED** | `zone.CURRENT_ZONE` → guarded; the MESH path took it directly and would throw for the swimming, fishing and ambience callers, all of which pass no zone. |
| P3 | Whirlpool sample point differs (rest vertex vs world point) | **LEFT** | Second-order (the shift is ~2 studs against a 150-stud radius). Flagged, not changed. |
| P4 | Every caller must pass the server clock | **ACCEPTED** | `WaveFloat.CheckClock(t)` warns once, in Studio only, when a sample time is more than 5 s from `workspace:GetServerTimeNow()`. |
| P5 | The inverse and the accuracy budget are untouched | **VERIFIED** | `bash tools/measure-height-error.sh` after the change: p99 **0.0094** studs at rough, **0.0091** live field (was 0.0094 / 0.0091), cost 3.97× (was 4.00×). R9 holds. |

---

## 2. What was implemented

- **`ParallelWorker.client.luau`** — rewritten around the review: state advances only on writes, a
  structure-of-arrays output, colour bucketing, shore cache on the snap epoch, per-attribute write
  counters, tag merge, no dead `FOV` listener, `DEBUG`-gated print, and the new two-array message
  contract.
- **`init.client.luau`** — plane-first retag order, partial tag messages sent only on change, sorted
  round-robin assignment, per-worker vertex lists, dead locals and the duplicate constant removed.
- **`WaveFloat.luau`** — nil-zone guard on the MESH path, clock guard, shore parity through
  `Helper.SHORE_HEIGHT_FACTOR`, and a private `WaveFloatShoreCache` SharedTable so the client's
  island cache can never decide a server's buoyancy.
- **`Gerstner/Types.luau`** — `VertexKey` gained `ShoreT` and `ColorBucket` (both are "what is in the
  mesh" caches; the comment says so, because that is the invariant W1 broke).
- **`Gerstner/Settings/init.luau`** — `LERP_MAX_FRAMES`, `COLOR_BUCKETS`, and the measured step table
  for `FAR_WRITE_EVERY_BEYOND`.
- **`Gerstner/Helper.luau`** — `SHORE_HEIGHT_FACTOR` as the single source of the near-shore factor.
- **`tools/smoke/tests.lua`**, **`tools/measure/stubs.luau`** — a `Helper` mock/stub, because
  `WaveFloat` now requires it (the harnesses load the real module).

## 3. Measurements

### The colour gate (W7) — A/B, four warm sessions each way

Variant A disables the gate (`COLOR_BUCKETS = 1000000`, i.e. old behaviour: every near vertex writes
a colour every frame); variant B is the shipped gate. Camera pinned identically in every session
(`CameraType = Scriptable`, `CFrame.new(0, 60, 400)` looking 25° down, `FOV 70`), 55 s warm-up, then
the worker's own `OCEANPERF` medians over ~50 reports per worker.

**The first comparison was invalid and the reason matters:** the Studio viewport was **1891×878 in
A** and **953×878 in B**, so the frustum held 13 chunks in A and 9.5 in B. Any per-frame comparison
between those two runs compares two different amounts of world. The honest normalisation is per
written vertex:

| quantity | A (gate off) | B (gate on) | change |
|---|---|---|---|
| position writes per vertex processed | 1.047 | 1.006 | unchanged |
| UV writes per position write | 0.185 | 0.181 | unchanged |
| **colour writes per position write** | **0.874** | **0.490** | **−44 %** |
| total API calls per vertex | 2.16 | 1.68 | **−22 %** |
| serial ms per position write | 0.905 µs | 0.942 µs | unchanged |

Raw sessions (pos / colour / uv / serial ms): A 222 / 194 / 41 / 0.201 and 203.5 / 181.5 / 37.5 /
0.182; B 155 / 76 / 28 / 0.146 and 155 / 50 / 28 / 0.139. The viewport difference is what moves the
raw counts; the per-vertex ratios agree between sessions on both sides.

Two things fall out of this:

1. **The 0.9 µs/call model is confirmed**: serial ms divided by calls is flat across both variants
   and every session, so a 22 % call reduction is a 22 % serial-section reduction at equal workload.
2. **What a player would see if the frame budget mattered**: with the near field in view, the serial
   section is roughly a fifth smaller in call count than before this pass (`W6` + `W7` together), and
   the pass also removed the per-vertex allocations that produced the 0.23 ms tail in `03-perf.md`.

### Correctness checks on the live mesh

- **The ocean animates.** Per-radius moving vertices after the change: 209/221 inside 100 studs,
  611/652 at 100–200, then the known tail (2/728 at 800–900) — the same profile as before the pass.
- **No worker errors.** Client console: no `ParallelWorker` errors, and none of the
  `attempt to get length of a nil value` that appeared during the intermediate broken build.
- **W1's failure mode is gone.** Colours beyond 400 studs: 1566 vertices at exactly
  `WATERLINE_COLOR`, 68 graded — and those 68 are the island-range and chunk-border cases where the
  graded path is correct by design, not stale writes.

## 4. What could not be verified

- **The parallel-time benefit of the sorted round-robin assignment.** The viewport difference
  between sessions swamped it, and the parallel section also fell with the colour work (−20 % in the
  same runs), so I cannot separate "better balance" from "less work".
- **A frame-rate or frame-time effect.** No fps claim is made anywhere in this document. The
  environment's per-session noise (and its changing viewport) is larger than the effect.
- **Whether the colour still looks right after quantising.** 1/64 of the ramp is 1.6/255 per channel
  in the arithmetic; nobody has looked at it. This is the first thing to check by eye.
- **Ships and props after the WaveFloat change.** The p99 height error is unchanged and the shore
  factor is inert with `DEPTH_ENABLED = false`, but a hull in the water is the check, and no hull was
  driven this pass.

## 5. What to try in Play

1. **Stand on a boat and look at a near-shore shelf** (or anywhere the water runs over sand). If the
   colour banding is visible as rings, the knob is `Settings.COLOR_BUCKETS` (raise it; 128 halves the
   step for the same call count only when the sea is flat, so expect the write count to rise).
2. **Rough sea, fast pan.** The near field is the band where colours are graded; if any of it reads as
   flat, that is the gate being too coarse in a steep patch.
3. **Sail into the RoughSea zone** (radius 300, amplitude ×2.5) and check the colour transition at the
   zone edge: the bucket encoding is what keeps the flat-band sentinel from being mistaken for a
   graded band there.
4. **A long session with the console open**: `Settings.DEBUG` builds print the per-worker chunk and
   vertex counts once at start and nothing else. Any `[OCEANPERF]` line means a measurement variant
   is still installed — the repo ships `REPORT_EVERY = 0`.
