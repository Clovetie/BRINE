# BRINE — Full Code Audit, Findings & Optimization Research

> **Scope.** A deep, read-only audit of every script in this repository. **No code
> was changed.** This document records what each module does, where it's used (or
> **not** used), concrete bugs and risks, and a prioritized list of optimizations
> and simplifications.
>
> Companion docs: [`ENVIRONMENT.md`](ENVIRONMENT.md) (how systems fit together),
> [`ROADMAP.md`](ROADMAP.md) (planned work). Tools referenced are in `tools/`.

---

## 0. How the audit was performed

- Read **every** `.luau` source file + every `.model.json` + `default.project.json`.
- Ran the project's own syntax checker:
  `node tools/check-syntax.js` → **all 8 Luau files parsed successfully.**
- Mapped the **call graph** with `grep`/`rg` across `src/` to find whether each
  public function is actually consumed inside this repo, or is library-only.
- Ran the evaluation gate:
  `node tools/evaluate-models.js --models tools/models.example.json --suite tools/evaluation-suite.example.json`
  → `fixture-known-good: ADMIT 100.0%` (deterministic fixture adapter) and
  `candidate-local: REJECT 0.0%` (missing adapter exercises the fail-closed path).

---

## 1. Files inventory & line counts

| File | Size (lines) | Role |
| --- | --- | --- |
| `Gerstner/init.luau` | ~310 | Gerstner wave math |
| `Gerstner/Types.luau` | ~25 | Type-only definitions |
| `Gerstner/Settings/init.luau` | ~155 | Waves + all tunables + seed |
| `Gerstner/Helper.luau` | ~328 | Frustum / color / transparency / UV / island-zone math |
| `Gerstner/HeightLookup.luau` | ~287 | Water height query (3 methods) |
| `Gerstner/Appearance.luau` | ~30 | **Placeholder** |
| `Gerstner/Serial/BoatManager.luau` | ~61 | Buoyancy math |
| `Gerstner/Serial/Setup/init.luau` | ~524 | Ocean mesh construction + subdivision |
| `Gerstner/Serial/ZoneManager/init.luau` | ~235 | Island/zone octree + multipliers |
| `Octree.luau` | ~373 | Generic spatial index |
| `IslandGeneration/IslandConfig.luau` | ~241 | Island tuning (data-only) |
| `IslandGeneration/IslandGenerator.luau` | ~1342 | Island streaming engine |
| `ServerScriptService/IslandGenerationServer.server.luau` | ~52 | Island orchestrator |
| `ServerScriptService/HandHoldingServer.server.luau` | ~591 | R15 hand-holding state machine |
| `StarterPlayerScripts/HandHoldingClient.client.luau` | ~99 | Hand-holding input |
| `Workspace/singletons/Ship/Handler.server.luau` | ~88 | Ship ownership/collision |
| `Workspace/singletons/Ship/Client.client.luau` | ~135 | Ship controls/buoyancy |
| `tools/*` | — | Dev tooling |

**Total source ≈ 6,300 lines** of Luau, dominated by `IslandGenerator` (~1,342)
and `HandHoldingServer` (~591).

---

## 2. Overall architecture assessment

### Strengths
- **Clean separation of concerns.** Wave math (pure), mesh building, height query,
  visual helpers, spatial index, zone manager, boat, islands, and hand-holding are
  each their own module.
- **Strong type hints** (`--!strict`, `--!optimize 2`, `--!native` on hot files)
  and `export type` definitions. Modern Luau idioms.
- **Determinism is a design goal.** `Settings.Seed` persists the world seed;
  `IslandGenerator` derives deterministic cell RNG from `(seed, cx, cz)`. Same
  seed → same world.
- **The Octree is dependency-free and reusable**, and both `ZoneManager` and
  `IslandGenerator` use it consistently.
- **Server-authoritative** where it matters (islands, hand-holding); clients only
  send lightweight intents.
- **Streaming is budgeted** (cells per cycle, yields, cap on rendered islands).

### Weaknesses / risks
- **No ocean renderer/orchestrator is present in the repo.** Many core functions
  (`Setup.SetupEditableMesh`, `Setup.SubdividePlane`,
  `Setup.SetupSecondaryPlanes`, `HeightLookup.ClientInit`, `Gerstner.SET_SETTINGS`,
  `Gerstner.ComputeTransformAndNormal`, `Helper.GetFrustumPlanes`, `Helper.IsInView`,
  `Helper.IsChunkInView`, `Helper.GetVertexColor`, `Helper.GetVertexTransparency`,
  `Helper.IsVertexNearShore`) have **zero callers** in this snapshot. This is the
  single biggest structural gap. They form a library that a missing driver script
  is supposed to consume.
- **The ship's buoyancy is effectively non-functional as shipped**, because
  `HeightLookup.ClientInit` (which sets the client `_PLANE`/`EditableMesh`) is
  never called. On the client, `HeightLookup.Lookup` early-returns `-1` for all 4
  buoyancy points.
- **Hot-path performance is heavy.** The ship calls `HeightLookup.Lookup` 4× per
  frame with `PRECISE`, and `PRECISE` recomputes `workspace:GetServerTimeNow()`
  many times per query and does a 24×8 triangle search.
- **A documented type mismatch** (`EditZone` BindableEvent vs RemoteEvent usage)
  and a **placeholder** (`Appearance`) block the ocean from rendering as designed.
- **Unbounded growth** in `IslandGenerator` (`allGeneratedRecords`, `cellCache`)
  and `ZoneManager` node scans (linear `GetAllNodes`), and an **unbounded**
  `activeRecords`/render-cache for long sessions.

---

## 3. Correctness bugs & contract issues (ranked)

### 🔴 P0 — Blocking / deterministically wrong

**B-1. `EditZone` is a `BindableEvent` but used as a `RemoteEvent`.** — ✅ *Fixed on `main`:* `EditZone.model.json` is now `RemoteEvent`; `validate-project.js` reports 0 errors.

*(Original finding:)*
`EditZone.model.json` declares `"className": "BindableEvent"`, yet
`ZoneManager/init.luau` calls `script.EditZone:FireAllClients(...)` (server) and
`script.EditZone.OnClientEvent:Connect(...)` (client). Neither exists on a
`BindableEvent`. This **errors at runtime** whenever a zone is inserted on the
server or when the client tries to subscribe. **Fix:** change the class to
`RemoteEvent` in `EditZone.model.json` (one word). (Noted in `README.md`; this is
a required change, not optional.)

**B-2. `Appearance` is a placeholder that breaks ocean rendering.** _Status: model replaced (ROADMAP 0.2); PBR maps still to add._
`Gerstner/Appearance.luau` returns `{}` and warns. `Setup.GetPlaneFromEditableMesh`
and `Setup.SetupSecondaryPlanes` **clone it onto every ocean plane** as the
material. With no `SurfaceAppearance`, ocean planes fall back to
`Enum.Material.Granite` with a flat color — no PBR water. **Fix:** supply a real
`SurfaceAppearance` (normal/roughness/metalness maps) and change the instance type
from ModuleScript to SurfaceAppearance.

**B-3. `HeightLookup.ClientInit` is never called → client buoyancy is -1.**
On the client, `HeightLookup.Lookup` begins with:
`if _PLANE == nil and IS_SERVER == false then warn(...); return -1`.
`_PLANE`/`EditableMesh` are only ever set by `ClientInit`, which no module calls
(confirmed across the repo). Therefore the ship's four buoyancy samples are all
`-1`, so `CalculateBuoyancy` produces a constant target instead of following
waves. **Fix:** call `HeightLookup.ClientInit(...)` from the ocean driver (or the
Ship client) once the client `EditableMesh`/plane is available. This is tied to
the missing orchestrator.

**B-4. `Gerstner.SET_SETTINGS` is never called → whirlpool UV math divides by 0.**
`GRID_INFO` initializes `Padding = 0`. `GetUVCoordinates` computes
`x = (Vx + (Padding*(Width-1)/2)) / Padding + 1` → **division by zero** when
`SET_SETTINGS` has not run. `GetVortexTransform` calls `GetUVCoordinates` for the
whirlpool `UVCenter` when none is cached. Because `SET_SETTINGS` has no caller,
any whirlpool UV-rotation path produces `NaN`/`inf`. **Fix:** call
`SET_SETTINGS(...)` from the (missing) driver, or default `GRID_INFO` to the
real grid values.

### 🟠 P1 — Likely wrong / risky under real use

**B-5. `Octree.GetRegionsInRadius` offset bug when `radius < octree.Size`.**
In the branch `if radius < octree.Size`, the 3×3×3 neighbourhood is sampled with
offsets of `Vector3.new(x * radius, ...)` instead of `x * size`. Because regions
are spaced by `size` (not `radius`), several of the 27 probes collapse onto the
same top region and an adjacent region can be **missed** when the point is near a
region boundary. **Fix:** use `x * size`, `y * size`, `z * size` (matching the
`maxOffset <= 3` branch).

**B-6. `Helper.GetZoneParameters` iterates ALL nodes (O(n)) each call.**
It uses `ZONE_TREE:GetAllNodes()` and `ISLAND_TREE:GetAllNodes()` and scans every
node, trusting `(NodePosition - Position).Magnitude < Radius`. This works, but it
is a full-tree scan. For the islands branch it also reads `Node.Position`; for
zones it reads `Data.Link.Position` (a part that should already be synced). It
ignores the octree's own `SearchRadius`/`ForEachInRadius`. **Fix:** use
`ForEachInRadius` with the max relevant radius.

**B-7. `BoatManager.CalculateBuoyancy` branch overlap / dead fallback.**
```
if Depth > -0.5 then ... return ...
elseif Depth < -0.25 then ... return ...
end
return Vector3.zero, Orientation, 0   -- unreachable for any finite Depth
```
For `Depth > -0.5` the first branch always runs; for `Depth <= -0.5` the second
branch matches (since `-0.5 < -0.25`). The final return is dead. Not harmful, but
the intent is unclear and it invites confusion. Also the clamped-depth behavior
between `-0.5` and `-0.25` is subtle.

**B-8. `HeightLookup` PRECISE: `workspace:GetServerTimeNow()` inside the hot loop.**
`local t = workspace:GetServerTimeNow()` is computed **inside** the
`for i = 1, 8` triangle loop, which itself is nested in `for SearchRegion = 0, 24`.
So one `PRECISE` lookup can call `GetServerTimeNow()` up to **~200 times**.
Hoist it to a single call at the top of `Lookup`. (This is the #1 cheap win.)

**B-14. `Ship/Client.client.luau:121` drives `AlignPosition.Position` with a
packed `(0, TargetY, 0)` from `BoatManager.CalculateBuoyancy`.** In
`Enum.PositionAlignmentMode.OneAttachment` the docs define `Position` as "the
position to which the constraint should move its `Attachment0`" — a **world**
point (this is also why the legacy `BodyPosition.Position` it replaced was
documented as "the target world position"). The ship only needs the Y, so the
zeroed X/Z become a command to slide the hull to the world origin, serviced out
of the same `MaxForce` cap as the lift because `ForceLimitMode` defaults to
`Magnitude`. The throttle `LinearVelocity` masks it while driving; an idle or
moored boat far from the origin feels the pull. **Fix:** write
`Vector3.new(Main.Position.X, height.Y, Main.Position.Z)`, and/or use
`ForceLimitMode.PerAxis` + `ForceRelativeTo.World` with
`MaxAxesForce = (0, lift, 0)` so buoyancy has no horizontal authority at all —
which is what `FloatingObjectGenerator`/`WaveFloat` do for the 500 props.
Left unfixed here on purpose: the ship is the author's working code and this
file records, not rewrites. — ✅ *Fixed on `main` (ROADMAP 2.5):* the ship uses
`PerAxis` + `World` with `MaxAxesForce = (0, lift, 0)`, and the goal's X/Z is the
mover attachment's own column. (Not `Main.Position`: the mover sits on `VehicleSeat`,
so `Main`'s X/Z would leave a constant horizontal offset.)

**B-9. `VertexPositionToId` keyed by `Vector3` — fragile float keys.**
`Setup` stores `VertexPositionToId[Position]` and `HeightLookup` reads it to get a
vertex id from a `Vector3`. Vector3 hashes are computed from float bits; two
mathematically-equal-but-bit-different vectors (or the same vector produced by
different arithmetic paths) will not match. Risk of `nil` index → `EM:GetPosition(nil)`
error. Combined with `UseNearbyVertices`, this is a correctness/robustness hazard.

### 🟡 P2 — Works but fragile / suboptimal

**B-10. `Helper.GetUV` uses `fmod` with a TODO** — the author already flagged it.
**B-11. `Setup` uses `Vector3` as table keys** for `_QUADS`/`_TRIANGLES`/`VertexInfo`
lookups — same float-key fragility as B-9.
**B-12. `Helper` module-level `FOV`/`ViewportRatio`** update from
`DiagonalFieldOfView`/`ViewportSize` signals, but frstum helpers read them; the
`DiagonalFieldOfView` signal recomputes using `FieldOfView` — minor semantic
mismatch.
**B-13. `IslandGenerator` `beginIslandSink`** removes the `"Island"` tag before the
model leaves `workspace.Map`; good, but a rising island that is interrupted may
leave stale octree nodes if `destroyRecordModel(record, permanent=false)` is
called while `record.node` still references a removed node.

---

## 4. Dead / library-only code (no in-repo callers)

Confirmed by grep across `src/`. These functions are **defined but never called**
inside this repository. They are almost certainly consumed by a **missing ocean
renderer** that is not part of this snapshot. Important: do **not** assume they're
unused and delete them — they are the intended public API of the ocean library.

| Function | Module | Why it exists |
| --- | --- | --- |
| `Gerstner.SET_SETTINGS` | Gerstner | Initialize the grid/UV globals used by whirlpool math. **Orphaned → B-4.** |
| `Gerstner.ComputeTransformAndNormal` | Gerstner | Per-vertex normals for accurate ocean lighting. |
| `Gerstner.ComputeWaveAndNormals` | Gerstner | (helper for the above) |
| `Gerstner.GetVortexTransform` | Gerstner | Whirlpool displacement + UV spin. **Only called from `HeightLookup`.** |
| `HeightLookup.ClientInit` | HeightLookup | Bind client `_PLANE`/`EditableMesh`. **Orphaned → B-3.** |
| `HeightLookup.Lookup(..., PRECISE_RAY)` | HeightLookup | Client-only local raycast height. |
| `Setup.SetupEditableMesh` | Setup | Build the ocean mesh. **Orphaned.** |
| `Setup.GetPlaneFromEditableMesh` | Setup | Turn mesh into a MeshPart plane. **Orphaned.** |
| `Setup.SubdividePlane` | Setup | Adaptive LOD subdivision. **Orphaned.** |
| `Setup.SetupSecondaryPlanes` | Setup | 8 tiled planes for a large ocean. **Orphaned.** |
| `Setup.MergeBorderVertex` | Setup | stitch LOD borders (internal). |
| `Helper.GetFrustumPlanes` | Helper | Compute the 6 frustum planes (culling). **Orphaned.** |
| `Helper.IsInView` | Helper | Point-in-frustum test. **Orphaned.** |
| `Helper.IsChunkInView` | Helper | Chunk-in-frustum test (6 offsets). **Orphaned.** |
| `Helper.GetVertexColor` | Helper | Wave height → color/foam/shore. **Orphaned.** |
| `Helper.GetVertexTransparency` / `IsVertexNearShore` | Helper | Depth-based shore transparency. **Orphaned.** |
| `Helper.GetTableLength` | Helper | Count array length. **Orphaned.** |

**What this means for the project:** the visible repo ships the **boat**, the
**island generator**, the **HandHolding system**, and the **ocean math/api**, but
**not the ocean's frame-to-frame editor/renderer**. That renderer would (a) call
`Setup.SetupEditableMesh`, (b) call `HeightLookup.ClientInit`, (c) each frame call
`Gerstner.ComputeTransformAndNormal`, `HeightLookup`, `Helper.GetVertexColor`,
`Helper.GetVertexTransparency`, `Helper.GetUV`, and `Helper.IsInView`/`IsInView`
per chunk, and (d) `Gerstner.SET_SETTINGS`. The next iteration of work should
either **add that driver** (to make the ocean actually render + the ship actually
float) or **document it as intentionally out-of-repo.**

---

## 5. Performance analysis

### 5.1 Hot loops / per-frame cost

| Site | Frequency | Cost | Recommendation |
| --- | --- | --- | --- |
| `Ship/Client` → `BoatManager.CalculateBuoyancy` | every `PostSimulation` | 4× `HeightLookup.Lookup(PRECISE)` | Biggest. Use `FAST` when far; reduce to 4 samples but cache; or compute height from the Gerstner analytic directly (much cheaper) and only fall back to mesh when near. |
| `HeightLookup.Lookup(PRECISE)` | per sample | 24 search regions × 8 triangles × ~4 `GetTriangleArea` + 3× `ComputeTransform` | Hoist `GetServerTimeNow()`; early-exit on first hit (already does); reduce search radius; skip `PRECISE` on the server unless needed. |
| `ZoneManager.GetZoneParameters` | every 3 s (ship) + on `ZoneUpdated` | full octree scans | Use `ForEachInRadius`/`SearchRadius` instead of `GetAllNodes()`. |
| `Helper.GetVertexTransparency` | per rendered vertex (if renderer present) | `workspace:Raycast` per unique vertex, cached in `SharedTable` | SharedTable is slower than a plain table (author noted). Use a plain Lua table on the client; keep the `NormalizedDistanceToIsland > 0.6` early-out; consider caching depth at coarse resolution. |
| `IslandGenerator` streaming step | every `GenerationInterval` (1.25 s) | bounds-checked, yields | Good already. Watch `isSpotClear`'s `searchRadius = radius + SpacingPadding + MaxIslandRadius` (up to ~870) — an octree query over a huge radius per candidate. Consider a cheaper nearest-neighbor check. |
| `Octree.GetNearest` | on zone insert | sorts all found nodes | Bounded nearest search (heap/partial sort) would avoid full sort; not hot enough to block. |

### 5.2 Allocation / GC pressure

- `Gerstner.GetVortexTransform` allocates many `Vector3`/`Vector2` per call; in
  `HeightLookup` it's called 3× per PRECISE triangle when a whirlpool zone is
  active. Only used when `ZONE.Type == 'Whirlpool'`.
- `SetupSecondaryPlanes` creates **8 identical MeshPart/SurfaceAppearance clones**;
  each is a replicated physical part. Large replication + memory cost. Consider a
  single larger plane or fewer tiles.
- `IslandGenerator.tweenModelPivot` creates a `CFrameValue` + 2 connections per
  rise/sink — fine, but `allGeneratedRecords`/`cellCache` grow unbounded over a
  long session (see 5.4).

### 5.3 Correctness/perf interplay: `DEBUG = true`

`_settings.DEBUG = true` in `Settings`. `HeightLookup.Lookup` warns
`'HEIGHT FAILED'` in the debug path, and `Settings`/`Setup` print/`warn` at load.
Disable debug in production to cut console churn and any per-frame warns.

### 5.4 Memory growth (long-session)

- `IslandGenerator.cellCache` and `allGeneratedRecords` grow **forever** by design
  (streaming cache). `cellCache` can be cleared; `allGeneratedRecords` is only
  cleared by `ClearGenerated`. Consider an LRU/eviction in a follow-up.
- `activeRecords` is bounded by `MaxRenderedIslands`. Good.
- `ZoneManager` `islandNodesByModel`/`islandDestroyConnections` are cleaned up.
- `ZoneManager` `ZONES` table appears to be appended-to but the code that splices
  into `ZONES` is not visible here (it's a module-local table declared and never
  populated in this file) — minor dead state.

---

## 6. Code quality review by file

| File | Notes |
| --- | --- |
| `Gerstner/init.luau` | Solid pure math. `SET_SETTINGS` orphaned. `for i, Wave in Waves` with unused `i`. A few module-locals (`PaddingMultiplier`, `UV_SCALE`) shadow `GRID_INFO` fields — easy to go stale. |
| `Gerstner/Types.luau` | Type-only; `ChunkKey` `ISLAND`/`ZONE` typed loosely (`{number|any}|nil`). |
| `Gerstner/Settings/init.luau` | Clear config. `BrownianMotionWaves(6)` is commented out; `workspace.GlobalWind` is only read there, so the dependency is latent. `FRUSTUM_CULLING_FIX` is set but **never read** (confirmed). |
| `Gerstner/Helper.luau` | The most feature-dense file. Frustum helpers orphaned. `BAND`/`GetTableLength` unused (BAND used only in `HashVector`). Good comments. |
| `Gerstner/HeightLookup.luau` | Effective but hot. `GetServerTimeNow` in loop; Vector3-key dictionary; `PRECISE_RAY` only client. |
| `Gerstner/Appearance.luau` | Placeholder with a `warn`. Must be replaced. |
| `Gerstner/Serial/BoatManager.luau` | Simple, correct math; branch overlap (B-7). |
| `Gerstner/Serial/Setup/init.luau` | Complex geometric code; heavy Vector3-key tables; the biggest single "missing caller" surface. |
| `Gerstner/Serial/ZoneManager/init.luau` | Good structure. **B-1** type mismatch; `GetZoneParameters` O(n); module runs `PostSimulation` on both server and client. |
| `Octree.luau` | Clean, well-typed. **B-5** radius-vs-size bug; `GetNearest` full sort. |
| `IslandGeneration/IslandConfig.luau` | Excellent data-only config, heavily commented. |
| `IslandGeneration/IslandGenerator.luau` | Big but well-structured; streaming/cache/activation separated. Watch `allGeneratedRecords` growth and `MaxIslandRadius`-inflated search radius. |
| `IslandGenerationServer.server.luau` | Clean thin orchestrator. |
| `HandHoldingServer.server.luau` | Thorough state machine. Many small allocations per heartbeat (snapshot table). Minor double-connection logic risk handled properly. |
| `HandHoldingClient.client.luau` | Simple; good toggle semantics. |
| `Ship/Handler.server.luau` | Correct ownership/collision-group wiring. `markIsland` only covers `workspace.Map` descendants, not `_RisingIslands` (rising islands aren't yet tagged). |
| `Ship/Client.client.luau` | Functionally complete but the buoyancy cost and the missing `ClientInit` (B-3) dominate. `maxForce`/`AssemblyMass` read once (writes not handled). |
| `tools/*` | Clean. `check-syntax.js` is a nice Luau-subset parser. `evaluate-models.js` is a solid fail-closed gate. |

---

## 7. Confirmed runtime-impacting issues summary (prioritized)

1. **P0** — `EditZone` must be a RemoteEvent (runtime error otherwise).
2. **P0** — `Appearance` must be a real SurfaceAppearance (ocean visual broken).
3. **P0** — Add `HeightLookup.ClientInit` (client buoyancy currently −1).
4. **P0** — Add a call to `Gerstner.SET_SETTINGS` (whirlpool UV div-by-zero).
5. **P1** — Fix `Octree.GetRegionsInRadius` offset (`radius` → `size`).
6. **P1** — Use radius queries in `GetZoneParameters` instead of full scans.
7. **P1** — Hoist `GetServerTimeNow()` out of the `HeightLookup` PRECISE loop.
8. **P2** — Reconsider the ship's 4× PRECISE lookups / use FAST far away.
9. **P2** — Swap `SharedTable` depth cache for a plain table (client).
10. **P2** — Reduce `SetupSecondaryPlanes` tile count (8 → configurable / fewer).
11. **P2** — Add eviction/limits to `IslandGenerator` growing caches.
12. **P2** — Disable `DEBUG` in production; remove/dead-code-annotate `FRUSTUM_CULLING_FIX`.

---

## 8. Optimization opportunities (grouped)

### A. Make the ocean actually render & float (the highest-value structural work)
The single most important "optimization" is not a micro-opt — it's **wiring the
libriary into a driver**. Adding (or restoring) an ocean **editor/renderer**
that:
- calls `Setup.SetupEditableMesh()` + `Setup.SubdividePlane(...)`,
- calls `HeightLookup.ClientInit(dict, mesh, plane)`,
- calls `Gerstner.SET_SETTINGS(...)`,
- each frame computes `Gerstner.ComputeTransformAndNormal`, then
  `Helper.GetVertexColor`, `Helper.GetVertexTransparency`, `Helper.GetUV`, and
  culls with `Helper.IsInView`/`Helper.IsChunkInView`,
would turn a "component library" into a running ocean and fix B-3/B-4. Without
this, the ship floats on a constant −1 and the ocean is uncolored/unrendered.

### B. Cheap correctness wins (no behavior change)
- `EditZone.model.json` → `RemoteEvent`.
- `settings.DEBUG = false` for production.
- Hoist `GetServerTimeNow()`.
- `Octree` radius→size fix.
- Ship buoyancy goal: keep the hull's own X/Z instead of `Vector3.new(0, Y, 0)`
  (B-14). Done for floating objects via `WaveFloat` and for the boat (ROADMAP 2.4/2.5).
- Floating-object buoyancy no longer samples `GetApproximateHeight` (`FAST`)
  and no longer skips the sample rig for small props — both were visible as
  props bobbing out of phase with the water and sitting dead level (fixed with
  `ReplicatedStorage/FloatingObjectGeneration/WaveFloat.luau`).

### C. Hot-path performance
- Ship buoyancy: use `FAST` (analytic) distance-culled; high detail only near the
  camera/boat.
- `ZoneManager` radius queries.
- Plain-table depth cache.

### D. Simplification
- Merge/replace the confusing `GRID_INFO` globals + copy locals in `Gerstner` with
  a single immutable settings read.
- Extract the per-frame ocean color/transparency logic into a reusable "render
  one vertex/chunk" function so the future driver is thin.
- Break `IslandGenerator` (1,342 lines) into smaller, named sub-modules
  (discovery, placement, activation, lifecycle) — it's readable now but large.
- Centralize the "waterline = `PLANE_OFFSET`" constant used by
  `Settings`, `HeightLookup`, `IslandConfig`, `Setup`, `IslandGenerator` to one
  source (currently mirrored manually and easy to drift).

---

## 9. Security / robustness notes

- **No client authority** over islands or hand-holding; good.
- **`evaluate-models.js`** is a legitimately fail-closed LLM gate: it hashes
  outputs by default (`--include-outputs` is opt-in/for-protected-debug), randomizes
  order with a seed, supports repeats, hard-fail categories, and never accepts the
  production prompt. Matches HELM/NIST-style pre-deployment guidance. The example
  now ships a deterministic fixture adapter (`tools/fixture-model.js`) so the gate
  is demonstrably green (`ADMIT 100%`), alongside a knowingly-broken
  `candidate-local` to exercise the fail-closed `REJECT` path. The interactive
  workbench (`tools/workbench.js`) and shared engine (`tools/lib/evaluate.js`)
  build on the same scorer.
- **Raycast/octree safety:** guard against `nil` vertex ids (B-9) before
  `EM:GetPosition`.
- **Collision groups:** ship uses `Ship`/`ShipIsland`; hand-holding uses
  `Characters`. Both disable only the intended pairs and use `pcall` to register.
  Islands placed by the generator are only tagged `"Island"` after publication, so
  rising islands are not yet in `Map` and may collide with the ship — worth
  tagging collision group earlier.

---

## 10. What a future AI should NOT change (guardrails)

- **Do not** delete the "orphaned" ocean API functions — they are the intended
  public interface for the missing renderer.
- **Do not** rewrite `Gerstner`, `Helper`, `HeightLookup`, `BoatManager`, `Octree`
  (per the original author's explicit guidance in `ISLAND_GENERATION_PROMPT.md`).
- **Do not** change the Rojo file-layout rules (Folder-with-children uses
  `init.luau`; `Serial` stays under `Gerstner`).
- **Do not** put generated artifacts or large datasets in Git (`.gitignore`
  already excludes builds, `.tools/`, `node_modules/`).
- **Do not** blindly "fix" the `FRUSTUM_CULLING_FIX` or `_QUADS`/`_TRIANGLES`
  Vector3-keyed tables without understanding the renderer contract — they are
  intended for the missing driver.

---

## 11. Verification evidence

```
$ node tools/check-syntax.js
OK   src/ReplicatedStorage/HandHolding/HandHoldingConfig.luau
OK   src/ReplicatedStorage/IslandGeneration/IslandConfig.luau
OK   src/ReplicatedStorage/IslandGeneration/IslandGenerator.luau
OK   src/ReplicatedStorage/Gerstner/Helper.luau
OK   src/ReplicatedStorage/Gerstner/Serial/ZoneManager/init.luau
OK   src/ServerScriptService/HandHoldingServer.server.luau
OK   src/ServerScriptService/IslandGenerationServer.server.luau
OK   src/StarterPlayerScripts/HandHoldingClient.client.luau

All 8 Luau file(s) parsed successfully.
```

```
$ node tools/evaluate-models.js --models tools/models.example.json --suite tools/evaluation-suite.example.json
fixture-known-good: ADMIT 100.0%
candidate-local: REJECT 0.0%
Report: evaluation-report.json
```

## 12. Machine-checked tooling (added this iteration)

The findings above are now reproducible with a self-contained Node toolkit in
`tools/` (no network to GitHub releases; `luaparse` is the only dep). Run all of
them with `bash tools/audit.sh` (or `--json` for machine-readable reports under
`tools/reports/`). These are the "future iteration" analysis harness:

| Tool | What it confirms |
| --- | --- |
| `tools/validate-project.js` | **B-1** (`EditZone` type mismatch) and Rojo layout errors. Exits 1 on error. |
| `tools/call-graph.js` | The orphaned/no-external-caller surface (`HeightLookup.ClientInit`, `Setup.*`, `Helper.*` frustum/color, `Gerstner.SET_SETTINGS`, etc.) and the genuine cross-module dependency graph. |
| `tools/metrics.js` | Complexity/LOC/heavy-construct trend (flags `IslandGenerator`, `HandHoldingServer`, `Setup` as the biggest). |
| `tools/find-dead-config.js` | The never-read knobs (`WORKER_COUNT`, `FrustumRenderDistance`, `MaxChunkRenderDistance`, `FRUSTUM_CULLING_FIX`). |
| `tools/hot-loop-scan.js` | **B-8** (`GetServerTimeNow` inside the HeightLookup PRECISE loop), `GetAllNodes` full scans, raycasts, per-frame work. |
| `tools/check-syntax.js` (existing) | Structural sanity for the conservatively-typed scripts. |
| `tools/evaluate-models.js` (existing) | Fail-closed model preflight gate (now demonstrably green via `tools/fixture-model.js`). |
| `tools/workbench.js` + `tools/lib/evaluate.js` (new) | Interactive model-eval workbench + shared scoring engine (exact/includes/regex/json/json_schema/code). |

These tools are heuristic, Luau-aware custom parsers (not a compiler); treat
their output as high-signal pointers that corroborate this audit's manual
findings, and verify before changing code.
