# Prompt: Immersive oceans and optimisation (BRINE)

You are working on the BRINE Roblox project at `/home/user/BRINE` (branch `main`), connected to Roblox Studio through the Arena bridge. The Studio place is the live source of truth; the repo is the version-controlled copy. Work in measured steps, verify each one, and report what you could and could not verify.

## Goal

Make the ocean look and feel immersive, and make it cheaper to run, without changing how the sea behaves physically. Two tracks, in this order:

1. **Optimisation first (measured).** Find where client frame time goes and cut it, with the look kept.
2. **Immersion second.** Improve what the player sees and hears at the water: the seam at the edge of the wave mesh, underwater view, surface detail, sound, and spray.

"Best solution" means the smallest change that gives a measured gain or a clear visual fix, not a rewrite.

## Context you must respect

- **The sea is shared physics.** `Gerstner` (`src/ReplicatedStorage/Gerstner/init.luau`), `Gerstner/Settings`, `WaveFloat`, `HeightLookup`, the ship (`Ship/Handler`, `Ship/Client`), floating objects, and the fishing bobber all read the same wave set and `SeaStateAt`. Do not change wave amplitudes, wavelengths, steepness, directions, or the sea-state field unless you re-check buoyancy for the ship, the floating objects, and the fishing rod. Visual-only changes are free.
- **Do not change `ServerBoat`.** It is the physics reference.
- **Fishing rod is parked as normal.** Do not change `src/Workspace/StickFishingRod/` unless a change in the ocean needs it.
- **Ship floating is calibrated.** Draft values (Template 5.9, Boat1 1.56, Boathouse 3.5, MisoSoup -7.3, WoodenShip SinkRestOffset -2.0, MisoSoup SINK_REST_OFFSET 2.4) must still hold after your change. Re-check one ship after any change that touches the sea.
- **Pushes and commits.** Push to Studio with `probes/push_src.py`. Commit locally as `Arena Agent <agent@arena.ai>`. Do not push to GitHub (no credentials). Do not commit the `tools/audit.sh` mode change.
- **Play sessions.** Settings changes in the Studio edit mode do not apply to a running Play session. Restart Play after changing renderer or Settings values.
- **Measurement limits.** `capture_viewport` is a software rasterizer. It does not show Roblox water shading, so it cannot judge the wave look. Use it only for layout. Judge the look with code review plus playtest notes, and say so in the report.

## Current state (from inspection, this session)

- The renderer is `src/StarterPlayerScripts/OceanParallel/` (`init.client.luau`, `ParallelWorker.client.luau`). It runs 6 Actor workers on `Heartbeat:ConnectParallel`. Each frame, every visible chunk loops over its vertices, calls the full 4-wave Gerstner transform, and, inside `task.synchronize()`, calls `EditableMesh:SetPosition`, `SetUV`, and `SetColor` on every changed vertex. The main-thread writes are the likely hot spot.
- The mesh is a 40 × 40 grid at 48-stud padding. Two subdivision rings (radius 400 and 200) add detail near the camera. Chunks are 100 studs. `FrustumRenderDistance` is 900, `LowRenderDistance` 200, `MaxChunkRenderDistance` 800.
- Vertices beyond `LowRenderDistance × 2` use a lerp path (LOD). Vertices inside it use the full per-frame computation.
- The 8 secondary planes (`Setup.SetupSecondaryPlanes`) are flat 4-vertex quads at the average sea height (`PLANE_OFFSET` Y 25). They do not carry waves. This creates a step at the edge of the wave mesh, which is about 936 studs from the camera.
- `Gerstner.ComputeTransform` calls `SeaStateAt` once per point, then sums 4 waves. `SeaStateAt` is 3 sines plus a smoothstep.
- Lighting has a Sky, Atmosphere (density 0.38, haze 1), Bloom, DepthOfField, and SunRays. There is no underwater effect in the Lighting service. Swimming (`src/StarterPlayer/StarterPlayerScripts/SwimClient.client.luau`, `src/ReplicatedStorage/Swimming/SwimModel.luau`) has a blue-ish tint when submerged. Check its details before adding anything.
- `Workspace.Ocean` is empty in edit mode. The renderer only runs in Play.

## Track 1: Optimisation (do first)

**Step 1.1: baseline.** Measure client frame time during a Play session with the ocean running. Use `run_playtest_scenario` with `clientCode` to sample `RunService.Heartbeat` dt over about 5 s after a warm-up. Record the mean, p95, and frame count. Also record the number of vertices and chunks rendered (count the workers' `Active` chunks if possible, or estimate from the grid). Save the numbers to `/home/user/ocean/NOTES.md`.

**Step 1.2: attribute the cost.** Hypothesis first, then test. Candidates, in likely order:
- main-thread `SetPosition`/`SetUV`/`SetColor` volume per frame;
- the per-frame `SetUV` write, which only changes slowly (UV scroll is 1/12 per second);
- the full Gerstner path on every vertex inside `LowRenderDistance × 2`;
- `SeaStateAt` evaluated per point;
- the `Heartbeat` rate, since waves at 60 Hz may be more than the eye needs at distance.

Test each candidate with one change at a time. Keep the change only if it lowers the measured mean frame time and does not add visible artifacts.

**Step 1.3: candidate fixes** (only if the test confirms the cost):
- Throttle far-chunk updates (e.g. update every N frames past a distance), using the existing lerp path for the in-between frames.
- Skip `SetUV` when the UV offset did not change by a visible amount, or update UV on a slower timer.
- Skip `SetColor` for vertices whose colour did not change by a threshold.
- Stop computing vertices outside the frustum with a tighter test, or lower `MaxChunkRenderDistance` if the horizon still reads correctly.
- Cache the per-point sea-state term per chunk, not per vertex, where the chunk is small.

**Step 1.4: server cost.** Benchmark `Gerstner.ComputeTransform` and `WaveFloat.HeightAt` cost in edit mode with `probe`, so the server buoyancy cost is known. Only change it if it is a measured hot spot.

**Acceptance for Track 1:**
- Client mean frame time with the ocean on drops by at least 25% against the Step 1.1 baseline, measured in the same way, with the same camera position and at least 3 runs.
- No new Studio warnings or errors (`get_console_output`).
- The wave motion looks the same from a distance (checked by code review of the change, and by a note on what was changed).
- The ship and floating props still float at the same heights (spot-check one ship and one prop).

## Track 2: Immersion (after Track 1)

Candidates to consider. Pick the ones that give the biggest visual or audio gain for the least risk, and say which ones you skipped and why.

1. **Seam at the wave-mesh edge.** The flat secondary planes sit at the mean height while the wave mesh rises and falls. Options: lower secondary tiles to a fixed low height under the waves, add a skirt of vertices that follows the edge wave height, or fade the secondary planes into the far horizon. Pick the cheapest one that removes the step.
2. **Underwater view.** When the camera is below the local sea height, apply an underwater look: a blue ColorCorrection or Atmosphere change, a short distance fog, and a muffled sound layer. Use the sea height from `WaveFloat.HeightAt` or `Gerstner` (client side, not a per-frame raycast). Keep the existing swimming tint and do not stack two effects.
3. **Surface detail and light.** The Appearance is a plain `SurfaceAppearance` with no PBR maps. Options: tune the vertex colour (CREST/TROUGH) and whitecap threshold for better foam, or add a subtle sun-glint through the Lighting Atmosphere. Do not add image assets unless the user asks.
4. **Ocean sound.** A quiet ambient sea loop and occasional crest sounds that follow sea state, with sounds from existing assets in the place or known Roblox asset IDs. Check the asset IDs are public and load before using them.
5. **Spray.** Small spray at crests near the camera or ship. Only if the particle budget allows, and capped in count.

**Acceptance for Track 2:**
- Underwater: the view changes within 0.3 s of crossing the surface, and returns on exit. Verified in a Play run by moving the character below the surface with a `clientCode` probe that reads the camera and the state.
- Edge seam: no visible step at the wave-mesh boundary in the Play camera reads, and no new per-frame cost above the Track 1 budget.
- No regression in the swimming tint, the bobber float, or the ship draft values.

## Verification you must run before pushing

- `node tools/smoke-test.js` (expected 83 pass, 0 fail, or the current count if the suite changed)
- `node tools/check-syntax.js` and `node tools/validate-project.js`
- `.tools/bin/luau-compile` on every changed `src/**/*.luau` file
- `.tools/bin/luau-analyze` on changed files (ignore Roblox global and type noise; fix real findings)
- Play run with `run_playtest_scenario`, console checked with `get_console_output` (Error and Warning)

## Deliverables

1. Changed repo files under `src/` and `tools/smoke/` where needed.
2. Pushed Studio copies via `probes/push_src.py`, read back to confirm.
3. `/home/user/ocean/NOTES.md`: baseline numbers, each candidate tested with its before and after numbers, what was kept and why, what was skipped, and what could not be verified.
4. A local commit (`Arena Agent <agent@arena.ai>`) with the ocean work. Not pushed.
5. A short report to the user: what got faster (with numbers), what looks different and how you know, and what still needs the user to look at in Play.
