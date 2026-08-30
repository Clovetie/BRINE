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
| 0.1 | 🔴 Change `EditZone.model.json` `"BindableEvent"` → `"RemoteEvent"` | `ZoneManager` uses `:FireAllClients`/`.OnClientEvent`; a BindableEvent doesn't have them → runtime error on zone insert. | S | Low (one word + regenerate) | Zone insert no longer errors; client receives zone events. |
| 0.2 | 🔴 Replace `Gerstner/Appearance.luau` placeholder with a real `SurfaceAppearance` (and set its instance type to SurfaceAppearance) | `Setup` clones it onto every plane; currently ocean renders as flat Granite. | M | Low–Med | Ocean planes show PBR water material; no `warn` at load. |
| 0.3 | 🔴 Call `HeightLookup.ClientInit(dict, mesh, plane)` once per client after the ocean mesh exists | Without it, client `PRECISE` lookups return `-1`, so the ship doesn't follow waves. | M | Med (needs the driver/mesh) | Ship buoyancy samples real wave heights on the client. |
| 0.4 | 🔴 Call `Gerstner.SET_SETTINGS(...)` with the real grid values (or default `GRID_INFO`) | Without it, whirlpool UV math divides by zero (`Padding=0`). | S | Low | Whirlpool UV rotation produces finite coordinates. |

---

## Phase 1 — Correctness & performance wins that are low-risk

| # | Item | Why | Effort | Risk | Acceptance |
| --- | --- | --- | --- | --- | --- |
| 1.1 | 🟠 Fix `Octree.GetRegionsInRadius` offset to use `size` (not `radius`) for the 3×3×3 neighbourhood | Small-radius queries near a region boundary can miss an adjacent region → missed islands/zones. | S | Low | Radius queries return all nodes within radius regardless of position within a top region. |
| 1.2 | 🟠 Hoist `workspace:GetServerTimeNow()` out of the `HeightLookup` PRECISE loop | ~200 calls per lookup down to 1. | S | Low | Per-lookup cost drops substantially; same behavior. |
| 1.3 | 🟠 Replace `GetZoneParameters` full octree scans with `ForEachInRadius`/`SearchRadius` | O(n) per call → O(local). Called by the ship every 3 s + on zone changes. | S | Low | Same output; fewer nodes visited. |
| 1.4 | 🟠 Use a plain Lua table instead of `SharedTable` for the vertex-transparency depth cache | `SharedTable` is slower (author noted). | S | Low | Identical cache behavior, faster writes/reads. |
| 1.5 | 🟡 Set `Settings.DEBUG = false` for production, or gate warnings | `HEIGHT FAILED` warns + load-time prints churn the console. | S | Low | No debug spam in production. |
| 1.6 | 🟡 Simplify `BoatManager.CalculateBuoyancy` branch logic (remove dead fallback, clarify `-0.5`/`-0.25` ranges) | Current ranges overlap are subtly confusing; final return is unreachable. | S | Low | Readable, documented depth thresholds. |

---

## Phase 2 — Boat / ocean interaction efficiency (the floating-realism payoff)

| # | Item | Why | Effort | Risk | Acceptance |
| --- | --- | --- | --- | --- | --- |
| 2.1 | 🟡 Distance-cull the boat's buoyancy sampling: use `HeightLookup.FAST` (analytic) when far, `PRECISE` only when near/special | 4× `PRECISE` per frame is the largest recurring cost. | M | Med | Ship follows waves accurately near the camera and cheaply far away; no visible pop. |
| 2.2 | 🟡 Cache/tune `maxForce`, `AssemblyMass`, and mover constants; recompute if the ship's mass changes | Values are read once; ship mass changes are ignored. | S | Low | Mover forces track ship mass at runtime. |
| 2.3 | 🟡 Reduce `SetupSecondaryPlanes` tile count or make it configurable | 8 identical replicated planes is a big replication/memory cost. | M | Med | Configurable tile count; acceptable visuals at lower counts. |
| 2.4 | ⚪ Add a `HeightLookup` analytic fast-path (single Gerstner call) for the boat center, with gradient-based pitch/roll | Cheaper than 4 mesh lookups; still smooth. | L | Med | Smooth, cheap buoyancy with minimal visual regression. |

---

## Phase 3 — The missing ocean renderer (the structural unlock)

This is the **biggest** opportunity: the repo is a component library without a
driver. Building/restoring the ocean renderer turns every orphaned API into a
running system.

| # | Item | Effort | Risk | Acceptance |
| --- | --- | --- | --- | --- |
| 3.1 | Add an ocean **editor/renderer** script that calls `Setup.SetupEditableMesh()`, `Setup.SubdividePlane(...)`, `Setup.GetPlaneFromEditableMesh(...)`, and `Setup.SetupSecondaryPlanes(...)` | L | Med | Ocean mesh + tiled planes appear in `workspace.Ocean`. |
| 3.2 | Call `HeightLookup.ClientInit(...)` from that renderer, and `Gerstner.SET_SETTINGS(...)` with grid values | M | Med | Fixes B-3/B-4; ship floats on real heights. |
| 3.3 | Per-frame vertex/chunk update loop: `Gerstner.ComputeTransformAndNormal` → `Helper.GetVertexColor`/`GetVertexTransparency`/`GetUV`, culled with `Helper.IsInView`/`Helper.IsChunkInView` | L | Med | Ocean animates with correct color/foam/shore/whirlpool effects, culled to the view frustum. |
| 3.4 | Wire `FRUSTUM_CULLING_FIX` into the culling path if it's still needed | S | Low | The flag is actually consumed. |
| 3.5 | Centralize the `PLANE_OFFSET` waterline into a single source consumed by `Settings`, `HeightLookup`, `Setup`, `IslandConfig`, `IslandGenerator` | S | Low | Changing waterline updates all consumers consistently. |

---

## Phase 4 — Island generation hardening & scaling

| # | Item | Why | Effort | Risk | Acceptance |
| --- | --- | --- | --- | --- | --- |
| 4.1 | ⚪ Bound/evict `IslandGenerator.allGeneratedRecords` and `cellCache` (e.g. LRU by last-touched) | These grow for the whole session by design; long servers accumulate. | M | Med | Memory stays bounded across long sessions. |
| 4.2 | 🟡 Reduce the inflatable octree search radius in `isSpotClear` (`+ MaxIslandRadius`) with a cheaper nearest-neighbor pre-check | Large per-candidate query. | M | Med | Same placement quality, faster validation. |
| 4.3 | 🟡 Split `IslandGenerator` (1,342 lines) into `discovery`, `placement`, `activation`, `lifecycle` sub-modules | Main engine is large and hard to extend. | L | Low | Each concern is a small, testable module; behavior unchanged. |
| 4.4 | ⚪ Tag the ship collision group on rising islands before they reach `Map` | Rising islands in `_RisingIslands` can collide with the ship. | S | Low | No ship↔island collision during rise animations. |

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
- **Is the ship the only floater, or are there plans for more?** If more, the
  buoyancy API should be promoted to a reusable "float" module (Phase 2.4 becomes
  higher priority).

---

## Guardrails (from the audit)

- Don't rewrite `Gerstner`, `Helper`, `HeightLookup`, `BoatManager`, or `Octree`;
  extend and wire them (original author's explicit guidance).
- Don't delete the orphaned ocean API — it's the intended interface.
- Don't break Rojo naming rules (Folder-with-children uses `init.luau`).
- Don't put generated artifacts/large datasets in Git.
