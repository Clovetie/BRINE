# BRINE — Improvement Roadmap

> **Purpose.** A prioritized, phased plan to **optimize and streamline** BRINE,
> focused on the findings in [`AUDIT.md`](AUDIT.md). Each item lists **why**,
> **what**, the **effort/risk**, and **acceptance criteria**. **No code was changed
> to produce this.** This is a plan for future iterations.

**Priority legend:** 🔴 P0 = blocking/do first · 🟠 P1 = high value · 🟡 P2 =
improvement · ⚪ P3 = nice-to-have.
**Effort:** S (<1 day) / M (1–3 days) / L (3–10 days) / XL (weeks).

---

## Phase 0 — Stop the bleeding (blocking correctness)

| # | Item | Why | Effort | Risk | Acceptance |
| --- | --- | --- | --- | --- | --- |
| 0.1 | ✅ DONE — Change `EditZone.model.json` `"BindableEvent"` → `"RemoteEvent"` | `ZoneManager` uses `:FireAllClients`/`.OnClientEvent`; a BindableEvent doesn't have them → runtime error on zone insert. | S | Low (one word + regenerate) | Zone insert no longer errors; client receives zone events. |
| 0.2 | ✅ DONE — Replace `Gerstner/Appearance.luau` placeholder with a `SurfaceAppearance` model (`Appearance.model.json`, matching the live place: grey, no PBR maps yet) | `Setup` clones it onto every plane; currently ocean renders as flat Granite. | M | Low–Med | Ocean planes show PBR water material; no `warn` at load. |
| 0.3 | ✅ DONE via 3.2 (`OceanParallel` calls `ClientInit` once the mesh exists) — was DEFERRED to 3.2: Call `HeightLookup.ClientInit(dict, mesh, plane)` once per client after the ocean mesh exists (no live caller needs it yet; `Workspace.Ocean` is empty) | Without it, client `PRECISE` lookups return `-1`, so the ship doesn't follow waves. | M | Med (needs the driver/mesh) | Ship buoyancy samples real wave heights on the client. |
| 0.4 | ✅ DONE — `Settings` calls `Gerstner.SET_SETTINGS(...)` with its real grid values (Padding 48, Width/Length 40) | Without it, whirlpool UV math divides by zero (`Padding=0`). | S | Low | Whirlpool UV rotation produces finite coordinates. |

---

## Phase 1 — Correctness & performance wins that are low-risk

| # | Item | Why | Effort | Risk | Acceptance |
| --- | --- | --- | --- | --- | --- |
| 1.1 | ✅ CHECKED, NO CHANGE — `Octree.GetRegionsInRadius` offset uses `radius`, but it is not a bug. For radius < region size, the probes at ±radius already reach any neighbour that holds an in-range node. Brute-force check (360 queries, radii 1–260, old and new code): 0 wrong results both ways. Original kept. Was: Fix `Octree.GetRegionsInRadius` offset to use `size` (not `radius`) for the 3×3×3 neighbourhood | Small-radius queries near a region boundary can miss an adjacent region → missed islands/zones. | S | Low | Radius queries return all nodes within radius regardless of position within a top region. |
| 1.2 | ✅ DONE — `HeightLookup` PRECISE reads the clock once per lookup (was once per triangle, ~200 calls). Server check: 40 lookups, 0 errors, ~3 µs each. Was: Hoist `workspace:GetServerTimeNow()` out of the `HeightLookup` PRECISE loop | ~200 calls per lookup down to 1. | S | Low | Per-lookup cost drops substantially; same behavior. |
| 1.3 | ⏸ TRIED, REVERTED — radius query was slower (11.3 ms vs 4.2 ms per 1500 lookups) because the map has a 300-stud zone, which sets the query radius; and it changed the winner for overlapping zones (1 of 1500 mismatches). Full scan kept (~3 µs per lookup, not a hot path). Was: Replace `GetZoneParameters` full octree scans with `ForEachInRadius`/`SearchRadius` | O(n) per call → O(local). Called by the ship every 3 s + on zone changes. | S | Low | Same output; fewer nodes visited. |
| 1.4 | ⏸ REVERTED — keep `SharedTable`. The live renderer (`StarterPlayer.StarterPlayerScripts.OceanParallel` → `ParallelWorker`) shares this depth cache across parallel Actors via `SharedTableRegistry`, and a plain table can't be shared between Actors. Was: Use a plain Lua table instead of `SharedTable` for the vertex-transparency depth cache | `SharedTable` is slower (author noted). | S | Low | Identical cache behavior, faster writes/reads. |
| 1.5 | ✅ DONE — `Settings.DEBUG = game:GetService('RunService'):IsStudio()`: Studio keeps the messages, live servers and clients are quiet. Was: Set `Settings.DEBUG = false` for production, or gate warnings | `HEIGHT FAILED` warns + load-time prints churn the console. | S | Low | No debug spam in production. |
| 1.6 | ✅ DONE (by 2.4) — `BoatManager` is now a thin adapter; no `-0.5`/`-0.25` branches or dead fallback remain (thresholds live in WaveFloat). Was: Simplify `BoatManager.CalculateBuoyancy` branch logic (remove dead fallback, clarify `-0.5`/`-0.25` ranges) | Current ranges overlap are subtly confusing; final return is unreachable. | S | Low | Readable, documented depth thresholds. |

---

## Phase 2 — Boat / ocean interaction efficiency (the floating-realism payoff)

| # | Item | Why | Effort | Risk | Acceptance |
| --- | --- | --- | --- | --- | --- |
| 2.1 | ⚪ SUPERSEDED — the ship uses the analytic surface (`ANALYTIC`, via 2.4), so the distance-cull to `PRECISE` is not needed. | The 4× `PRECISE` cost is gone with the analytic solver. | — | — | — |
| 2.2 | ✅ DONE — `RefreshForceLimits()` in `Ship/Client.client.luau` recomputes `maxForce`, `throttleForce`, and the mover limits when `AssemblyMass` changes. Verified in play: adding a 20-stud weight takes mass 2818 → 8418 and the limits follow; removing it restores the originals. Hover A/B against the pre-2.2 Client showed no regression. | Values are read once; ship mass changes are ignored. | S | Low | Mover forces track ship mass at runtime. |
| 2.3 | ✅ DONE — `Settings.GRID_SETTINGS.SECONDARY_PLANES` (0–8, default 8) drives `SetupSecondaryPlanes`. Default verified in play (`workspace.Ocean` = OceanPlane + 8 SecondaryPlane). Lower counts (4 / 0) are not yet run in play; the clamp was checked for edge values. | 8 identical replicated planes is a big replication/memory cost. | M | Med | Configurable tile count; acceptable visuals at lower counts. |
| 2.4 | ✅ DONE — Shared the buoyancy solver: the ship now runs on `ReplicatedStorage.FloatingObjectGeneration/WaveFloat.luau` (`WaveFloat.Solve`, `ANALYTIC` source) and `BoatManager.CalculateBuoyancy` is a thin compatibility adapter over it | One motion model for the boat and the 500 props. The ship no longer needs `HeightLookup.ClientInit` to float (the old 4× `PRECISE` path returned `-1` on a client without it). | M | Med | Ship and props call the same solver; `BoatManager` is an adapter. |
| 2.5 | ✅ DONE — Ship goal no longer pins X/Z to the world origin (`Ship/Client.client.luau`). Also: the `ShipThrottle` LinearVelocity is horizontal-only (PerAxis, zero Y authority), so it no longer holds the hull at its height; the throttle drives along the flat heading | In `OneAttachment` mode `Position` is a world goal. The ship now uses `ForceLimitMode.PerAxis` + `ForceRelativeTo.World` with `MaxAxesForce = (0, lift, 0)` and writes the goal's X/Z as the mover attachment's own column (zero horizontal error). The lift is no longer shared with a horizontal pull toward the origin. | S | Low | Idle boat stays where the water leaves it; buoyancy force does not vary with distance from the origin. |
| 2.6 | ✅ DONE — `Ship/Handler.server.luau` anchors every ship part while the seat is empty and unanchors on boarding (re-anchors on exit). Before: the boat free-fell out of the world about 2 s after play started unless someone sat in it (spawned at y 35.6, kill plane -500). | The unseated hull fell past `FallenPartsDestroyHeight` and was destroyed, which looked like the boat disappearing. | S | Low | An empty ship does not fall into the void. Known limit: an empty ship stays frozen where it was left (for example, y 19 after an ejection). Deciding whether it should float unmanned is open. |

---

## Phase 3 — The missing ocean renderer (the structural unlock)

This is the **biggest** opportunity: the repo is a component library without a
driver. Building/restoring the ocean renderer turns every orphaned API into a
running system.

| # | Item | Effort | Risk | Acceptance |
| --- | --- | --- | --- | --- |
| 3.1 | ✅ DONE — The renderer was already live as `StarterPlayer.StarterPlayerScripts.OceanParallel` (not in the repo). Synced to `src/StarterPlayerScripts/OceanParallel/init.client.luau` + `ParallelWorker.client.luau`. Playtest: `Workspace.Ocean` holds OceanPlane + 8 SecondaryPlanes (1872² studs, Y=25). Was: Add an ocean **editor/renderer** script that calls `Setup.SetupEditableMesh()`, `Setup.SubdividePlane(...)`, `Setup.GetPlaneFromEditableMesh(...)`, and `Setup.SetupSecondaryPlanes(...)` | L | Med | Ocean mesh + tiled planes appear in `workspace.Ocean`. |
| 3.2 | ✅ DONE — `OceanParallel` calls `HeightLookup.ClientInit(...)`; `Settings` calls `SET_SETTINGS` with the grid values (0.4). Was: Call `HeightLookup.ClientInit(...)` from that renderer, and `Gerstner.SET_SETTINGS(...)` with grid values | M | Med | Fixes B-3/B-4; ship floats on real heights. |
| 3.3 | ✅ DONE (live, now synced) — chunked parallel worker: frustum culling, LOD lerp, colour/foam, UV scroll, whirlpool and island/zone multipliers. Presence verified in play; wave motion and culling not measured yet. Was: Per-frame vertex/chunk update loop: `Gerstner.ComputeTransformAndNormal` → `Helper.GetVertexColor`/`GetVertexTransparency`/`GetUV`, culled with `Helper.IsInView`/`Helper.IsChunkInView` | L | Med | Ocean animates with correct color/foam/shore/whirlpool effects, culled to the view frustum. |
| 3.4 | ✅ DONE (retired) — `FRUSTUM_CULLING_FIX` removed from `Settings` and from the renderer. The `Highlight` it created was `Enabled = false`, so it never affected rendering, and the ocean already shows up without it. Enabling it would change the render path and I could not verify culling in this harness, so the flag was retired rather than enabled. Was: Wire `FRUSTUM_CULLING_FIX` into the culling path if it's still needed | S | Low | The flag is actually consumed. |
| 3.5 | ✅ DONE — `Settings.GRID_SETTINGS.PLANE_OFFSET` is the source; `Setup`'s default now reads it too (it was `Vector3.zero`). Other consumers already read Settings. Was: Centralize the `PLANE_OFFSET` waterline into a single source consumed by `Settings`, `HeightLookup`, `Setup`, `IslandConfig`, `IslandGenerator` | S | Low | Changing waterline updates all consumers consistently. |

---

## Phase 4 — Island generation hardening & scaling

| # | Item | Why | Effort | Risk | Acceptance |
| --- | --- | --- | --- | --- | --- |
| 4.1 | ⚪ Bound/evict `IslandGenerator.allGeneratedRecords` and `cellCache` (e.g. LRU by last-touched) | These grow for the whole session by design; long servers accumulate. | M | Med | Memory stays bounded across long sessions. |
| 4.2 | 🟡 Reduce the inflatable octree search radius in `isSpotClear` (`+ MaxIslandRadius`) with a cheaper nearest-neighbor pre-check | Large per-candidate query. | M | Med | Same placement quality, faster validation. |
| 4.3 | 🟡 Split `IslandGenerator` (1,342 lines) into `discovery`, `placement`, `activation`, `lifecycle` sub-modules | Main engine is large and hard to extend. | L | Low | Each concern is a small, testable module; behavior unchanged. |
| 4.4 | ✅ DONE — `Ship/Handler.server.luau` now also tags `workspace._RisingIslands` descendants `ShipIsland` (watches the folder, including when it is created later). Verified in a server run: parts added to the folder get `CollisionGroup = ShipIsland`. | Rising islands in `_RisingIslands` can collide with the ship. | S | Low | No ship↔island collision during rise animations. |

---

## Phase 5 — Hand-holding polish

| # | Item | Effort | Risk | Acceptance |
| --- | --- | --- | --- | --- |
| 5.1 | ⚪ Reduce per-heartbeat allocations in `HandHoldingServer` (avoid building a snapshot table each frame; iterate state directly) | S | Low | Same behavior, fewer GC hits. |
| 5.2 | ⚪ Consider a server-side target-lock re-pick if the original target leaves the cone while holding | S | Low | Smoother UX; current behavior simply force-drops on out-of-range. |
| 5.3 | ⚪ Add a config-driven cooldown on re-offer to prevent offer spam | S | Low | Rate-limited offers. |

---

## Phase 6 — Tooling & reproducibility

**Status:** much of Phase 6 is now implemented. The reusable analysis toolkit lives
in `tools/` and is runnable with only Node + `luaparse` (no network to GitHub
releases). See [`tools/README.md`](tools/README.md).

| # | Item | Effort | Risk | Acceptance |
| --- | --- | --- | --- | --- |
| 6.1 | Make `setup-tools.sh` resilient to GitHub release-supplier flakiness (retry + alternate mirror) | M | Low | `stylua`/`selene`/`luau` install reliably in CI/dev. ✅ retried + Rokit tip added |
| 6.2 | Add a `luau-analyze` / `selene` CI step (currently only `check-syntax.js` is runnable without the full toolchain) | M | Low | Static analysis gate in CI. ✅ `.github/workflows/ci.yml` |
| 6.3 | ✅ DONE — Swap the example LLM adapter for a real fixture so the preflight gate is demonstrably green before use | S | Low | `evaluate-models.js` shows `ADMIT` on a known-good adapter. The committed example ships `tools/fixture-model.js` (deterministic demo adapter) so the gate is green end-to-end, plus `candidate-local` to exercise the fail-closed `REJECT` path. |
| 6.4 | ✅ DONE — `tools/call-graph.js` (dep graph + orphaned/public-API surface) | — | — | Machine-checks AUDIT §4. |
| 6.5 | ✅ DONE — `tools/metrics.js` (LOC/complexity/heavy-construct trend) | — | — | Spots the largest/hottest files per iteration. |
| 6.6 | ✅ DONE — `tools/validate-project.js` (Rojo layout + `.model.json` contract gate) | — | — | Fails CI on the `EditZone` type bug & layout mistakes. |
| 6.7 | ✅ DONE — `tools/find-dead-config.js` (unused settings knobs) | — | — | Flags `WORKER_COUNT`/`FrustumRenderDistance`/`MaxChunkRenderDistance`/`FRUSTUM_CULLING_FIX`. |
| 6.8 | ✅ DONE — `tools/hot-loop-scan.js` (per-frame/loop risk) | — | — | Flags `GetServerTimeNow` in HeightLookup loop, `GetAllNodes`, raycasts. |
| 6.9 | ✅ DONE — `tools/audit.sh` orchestrator + `tools/lib/luau.js` shared engine | — | — | One command runs everything; JSON reports in `tools/reports/`. |
| 6.10 | ✅ DONE — `tools/workbench.js` interactive evaluation workbench + `tools/lib/evaluate.js` shared scoring engine; expanded example suite | — | — | List/add/remove models & tests, run the suite with per-test pass/fail, write JSON reports, and a demonstrably-green example. |

---

## Suggested sequencing (roadmap order)

1. **Phase 0** (correctness blockers) — unblock the ocean and ship.
2. **Phase 1** (low-risk perf/correctness) — cheap, safe wins.
3. **Phase 3** (build the renderer) — make the ocean real; enables everything else.
4. **Phase 2** (boat efficiency) — once the ocean renders, tune buoyancy.
5. **Phase 4** (island scaling) — bound memory and shrink the engine.
6. **Phase 5 / 6** (polish + tooling) — as capacity allows.

---

## Decision points to confirm before implementation

- **Is the ocean renderer intended to live in-repo or is it deliberately external?**
  This decides whether Phase 3 is "add a script" or "document the contract." (The
  repo currently leans external.)
- **Should `Appearance` be a `SurfaceAppearance` (PBR) or a simpler material?**
  Affects Phase 0.2 scope.
- **What island count / world size is the target?** Drives Phase 4 tuning
  (`MaxRenderedIslands`, generation radius, tile count) and Phase 5 budgets.
- **Is the ship the only floater, or are there plans for more?** Answered for
  props: `FloatingObjectGeneration/WaveFloat.luau` is the reusable "float" module
  (analytic surface + 4 hull attachments + the ship's drag/airborne model), and
  every buoyant object uses it. The open question is the reverse — whether the
  ship should be moved *onto* it (Phase 2.4) so there is one motion model.

---

## Guardrails (from the audit)

- Don't rewrite `Gerstner`, `Helper`, `HeightLookup`, `BoatManager`, or `Octree`;
  extend and wire them (original author's explicit guidance).
- Don't delete the orphaned ocean API — it's the intended interface.
- Don't break Rojo naming rules (Folder-with-children uses `init.luau`).
- Don't put generated artifacts/large datasets in Git.
