# 02: Wave collisions and visual spasms (P0)

## The problem, as the user reported it
1. **Visual spasms during rough waves.** The sea shimmers or jitters when the waves are rough.
2. **Spasms during the transition between calm and rough (and back).** The jitter appears as the sea changes between calm and rough.
3. **Waves are colliding.** Objects, ships, and the sea do not agree on height: things sink into the visible water or hover above it. The user has not confirmed the exact symptom. Ask for a screenshot or a short clip before you conclude what "colliding" means. Until then, treat it as a physics-versus-visual height mismatch.

## Context
- The sea is a Gerstner field. Four waves, with wavelengths 58, 41, 30, and 25. Steepness 0.26, 0.20, 0.14, and 0.09. Amplitude sum about 4.7 studs.
- A slow **sea-state field** scales all amplitudes per point. Calm is `Gerstner.SEA_STATE_CALM` = 0.3, rough is 1. It is defined in `src/ReplicatedStorage/Gerstner/init.luau` (`SeaStateAt`, around line 137). It drifts over minutes.
- `Gerstner.ComputeTransform(Waves, Position, t, ...)` returns a **displacement** for a rest point. The visible vertex is at `rest + displacement`. The physics height is `PLANE_Y + ComputeTransform(point).Y` (`WaveFloat.HeightAt`, and `HeightLookup` for the mesh source).
- The visible mesh is written by `StarterPlayerScripts/OceanParallel/ParallelWorker.client.luau`. Near vertices are full-quality. Far vertices (beyond `LowRenderDistance` 200) use a lerped path that evaluates the transform at two times, `t` and `t + dt*LERP_MAX_FRAMES` (around lines 217 to 225).
- Settings are in `src/ReplicatedStorage/Gerstner/Settings/init.luau`: `PERF.FAR_WRITE_EVERY = 3`, `PERF.UV_WRITE_EVERY = 3`, `MeshDetailDistance = 120`. The last three were added in this session. **The first two are the top suspects below.**

## Suspects, ranked (verify each one; do not assume)

**S1. Far-vertex write budget (introduced this session; most likely cause of the spasms).** Far vertices and the UV scroll are written every 3 frames instead of every frame. At rough amplitudes a far vertex moves about 0.12 stud per step (vertical speed up to about 2.5 studs/s over 3 frames). Near and far vertices then update on different frames, which reads as a 20 Hz jitter, worst in rough seas. Test: set `FAR_WRITE_EVERY = 1` and `UV_WRITE_EVERY = 1`, rerun the same scene, and compare the per-frame vertex motion (task 2 below). If S1 accounts for the spasm, the budget must go, or be made phase-aware (write the far vertices on the same frame as their neighbours, or lerp between writes).

**S2. Rest-versus-displaced mismatch (the most likely source of the collisions).** The mesh draws a vertex at `rest + D(rest)`. Physics reads `PLANE_Y + D(point).Y` at the rest point, with no inverse mapping. Gerstner waves move points horizontally by up to about the wave amplitude times the steepness ratio, so near steep waves the horizontal shift can be a stud or more. The height read at the wrong XZ is then wrong by up to the local slope times that shift. Rough seas raise both the amplitude and the shift, so the error grows with roughness. Test: sample 100 rest XZ points at roughness 0 and at roughness 1. For each, compare the mesh vertex world Y (after displacement) against `WaveFloat.HeightAt` at the same world XZ. Record the error distribution. Fixes to evaluate: an inverse mapping (two or three Newton steps from the world XZ to the rest point) in `HeightAt` and `GetApproximateHeight`; or a horizontal-displacement clamp in rough seas. Do not change the wave design numbers without the user's approval.

**S3. Sea-state term in the lerp path.** `SeaStateAt` is evaluated at the rest point and depends on time. The far-vertex lerp mixes the transform at two times. If the amplitude multiplier changes between those times, the lerp mixes two amplitudes, and the error is not the linear-wave error the design assumed. Test: compare the lerped far vertex with a full evaluation at the same time, across a calm-to-rough change. Record the error.

**S4. Detail boundary at 120 studs.** `MeshDetailDistance` = 120 switches vertices between the full path and the lerped path. A boundary that moves with the camera, with a 3-frame update on one side, can shimmer. Test: step the camera across the boundary and watch the per-vertex delta around it.

**S5. Zone multipliers in one path only.** Island and whirlpool zones carry `PhaseMultiplier`, `SpeedMultiplier`, and `AmplitudeMultiplier`. Confirm that the mesh path (`ParallelWorker`, via `ZoneManager`) and the physics path (`WaveFloat.HeightAt(point, zone, ...)`) apply the same values. Record any mismatch.

**S6. Stale far chunks.** Chunks beyond `MaxChunkRenderDistance` 800 get no computation and keep their last state. Confirm whether a stale chunk visibly disagrees with its neighbours when the camera moves. (The seam work in `04` is related.)

## Tasks
1. Reproduce. Start Play. Put the camera at a calm point and at a rough point (scan `SeaStateAt` over a grid to find them; the field drifts, so scan right before each test). Record a short sequence of frames and the sea state.
2. **Measure vertex motion** (for S1 and S4). From a client probe, read a chunk's EditableMesh vertex positions over about 10 seconds (in windows under 15 seconds). Compute the per-frame change of each vertex. Report the maximum change and the 99th percentile for near and far vertices, separately.
3. **Measure the height error** (for S2 and S3). As described under S2.
4. **Calm-to-rough transition.** Force or wait for a transition. Record the same measurements across the transition.
5. Change one suspect at a time. Rerun the measurement after each change. Keep a table of the results.
6. Confirm the cause with the user's own view. Ask the user for a short clip or screenshot if the metrics do not explain the symptom.

## Acceptance criteria
- A1: The height error between the rendered mesh and physics, measured at 100 random points at roughness 0 and at roughness 1, is at most 0.1 stud at the 99th percentile. Record before and after.
- A2: The far-vertex and near-vertex motion over 600 frames of a calm-to-rough transition does not show a periodic 3-frame pattern. Record the autocorrelation or the frame-delta histogram.
- A3: No regression in the ocean performance numbers in `docs/work-notes/ocean/NOTES.md`, or the regression is recorded and accepted by the user.
- A4: Ships, floating objects, and swimming still float at the correct height (see `07` and `08`), checked with the existing probes.
- A5: The user confirms the spasms and the collisions are gone, by eye, in Play.

## Verification notes
- `capture_viewport` cannot judge water, so visual checks are the user's job. Say so in the report.
- Measure in windows under 15 seconds (client RPC limit).
- The sea-state field has a period of about 10 minutes. Note the time of each run.

## Do not
- Do not change `ServerBoat`.
- Do not change the wave design numbers (wavelengths, steepness, amplitudes) without the user's approval.
- Do not add an overhang-sink rule for unsupported platforms.
- Do not work around the symptom by hiding it with fog or by lowering the amplitude, unless the user asks for that as a design choice. Record it as one if you do.

## Deliverables
- `docs/audit/02-waves-findings.md`: the measurements, the ranking, and what was confirmed.
- The fix commits, each with its measurement in the body.
- A short note to the user on what they should look at in Play.
