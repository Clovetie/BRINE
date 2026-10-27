# 10 — The water's look: the optimisations that were fighting the render

The user's report after the ship work: *"further water optimisation and visual artefacts (it's
currently conflicting I'm pretty sure)"*. That reads as one question: the water is being drawn by
several shortcut paths at once, and they disagree with each other where they meet.

This pass measured each of those meeting points on the live mesh, fixed the three that are outright
wrong, and recorded the two that are structural (a budget decision and a content decision) rather
than changing them unilaterally.

**How everything here was measured.** A client probe during Play reads the rendered mesh, not the
analytic surface:

```lua
local em = game:GetService("AssetService"):CreateEditableMeshAsync(plane.MeshContent)
em:GetVertices() / em:GetPosition(id) / em:GetColors() / em:GetUVs()
```

That is the geometry the player actually sees, after every worker, LOD and write-budget decision has
been applied. Each read costs ~4 ms, so the loops sample a mesh snapshot per probe, never per frame
(except the step measurement in §6, which re-creates the copy once per Heartbeat and is labelled as
such). Probes: `/tmp/ocean_seam.lua`, `/tmp/ocean_colour.lua`, `/tmp/ocean_uv.lua`,
`/tmp/ocean_cliff.lua`, `/tmp/ocean_err.lua`, `/tmp/vortex.lua`, `/tmp/step.lua`.

---

## 1. The colour ramp was sized for a sea three times this one — FIXED

`Helper.GetVertexColor` mapped wave height to the TROUGH → CREST colour with a hardcoded

```lua
COLOR_LOW:Lerp(COLOR_HIGH, min(((TransformY + -1) * 4) / 30, 1))
```

which reaches CREST at `TransformY = 8.5` studs and never gets there: a Gerstner vertex cannot leave
the sum of the wave amplitudes, and the shipped set sums to **4.7317** studs
(0.26·58/2π + 0.20·41/2π + 0.14·30/2π + 0.09·25/2π). Below `TransformY = -1` the old code *clamped*
the height, so every trough deeper than one stud got the same colour — and that colour was
`Lerp(..., 0)`, i.e. TROUGH, while the ramp's own arithmetic continued *below zero* for anything
between -1 and 0, extrapolating outside the colour pair.

Measured on the live mesh, all 3301 vertices, blend factor along TROUGH → CREST (0 = TROUGH, 1 =
CREST):

| distance from mesh centre | n | rendered Y | mean blend |
|---|---|---|---|
| 0–120 | 313 | -1.55 … 2.35 | **-0.131** |
| 120–400 | 1364 | -2.92 … 2.75 | **-0.126** |
| 400–800 | 896 | -1.31 … 1.35 | **-0.103** |
| 800–936 | 312 | -1.33 … 0.00 | **-0.131** |
| > 936 | 416 | 0.00 | **-0.130** |

So the whole sea was rendered *below* the TROUGH colour (13 % past it, towards black), the CREST
colour was never drawn, and the far LOD band (§2) was the only thing near the intended palette. A
sea with a single flat-looking colour is exactly what "conflicting" looks like when you expect
crest/trough shading.

**Fix.** The ramp is now normalised by the wave set's own envelope instead of studs:
`blend = clamp(Y / CREST_ENVELOPE * 0.5 + 0.5, 0, 1)`, where `CREST_ENVELOPE` is the sum of the
4 wave amplitudes, computed from `Settings.Waves` at load. The clamp is on the *normalised* value,
so a colour can no longer leave the pair.

Run `bash tools/measure/colour-ramp.sh` (new; runs the **real** `Helper.luau` headless with a
`Color3`/`Camera`/`Settings` stub — the wave table is built with the real `Gerstner.new`):

| Y (studs) | old blend | new blend |
|---|---|---|
| -4.732 (envelope) | -0.267 | **0.000** |
| -2.920 (measured trough) | -0.267 | 0.191 |
| -1.000 | -0.267 | 0.394 |
| 0.000 (waterline) | -0.133 | **0.500** |
| +1.000 | 0.000 | 0.606 |
| +2.350 (typical crest) | 0.180 | 0.748 |
| +2.920 (measured crest) | 0.256 | 0.809 |
| +4.732 (envelope) | 0.498 | **1.000** |

Ramp span over the full envelope: `0.000 … 1.000` (was `-0.267 … 0.498`).

Re-measured on the live mesh after the fix, mean blend **0.502 / 0.474 / 0.492 / 0.493 / 0.492** by
band: the near field is now centred on the palette instead of below it, and every band agrees (that
agreement is what makes §2 work).

**Whitecaps are still off, by construction.** `WHITECAP_HEIGHT = 6` studs against an envelope of
**4.7317** — no vertex can ever reach it, and the measured maximum was 2.92 studs. The branch is now
commented as unreachable rather than deleted. Turning whitecaps on is a look decision (a smaller
threshold, or a threshold in envelope fractions); it is **not** a bug fix and was left to the user.

## 2. The far-field LOD painted itself the TROUGH constant — FIXED

Past `LowRenderDistance * 2` (400 studs) the worker skipped the ramp and wrote a flat
`WAVE_COLORS.TROUGH` for every low-detail vertex; it also skipped the *write* when the colour was
still TROUGH (`ParallelWorker` `UpdateSecondary`), which is why the far field is cheap.

That band used to be the brightest thing in the frame by accident (§1: mean -0.13 everywhere else).
With the ramp fixed it would have become a **dark ring at 400 studs**, so both move together: the
flat colour is now `Helper.WATERLINE_COLOR` = the ramp at blend 0.5, which is what the graded near
field averages to. Measured per band after the change: 0.502 (near) vs 0.492 (beyond 400) — a
0.01 difference against the previous 0.5-scale disagreement. The write-skip gate compares against the
same new constant, so the far field still does not write colours every frame.

## 3. The eight far tiles were a different texture scale — FIXED

`Setup.SetupSecondaryPlanes` computed the tile UVs from its own formula (`x = Vx / Padding + 1`),
while the main plane's vertices use `GetUVCoordinates` × `UV_SCALE`:

| | UV at local X = -936 | at 0 | at +936 | studs per UV unit |
|---|---|---|---|---|
| main plane | — | 41.00 | — | **24** |
| far tile, before | -18.50 | 1.00 | 20.50 | **48** |
| far tile, after | 2.00 | 41.00 | 80.00 | **24** |

At the seam where the tiles meet the main plane (local ±936), the texture therefore jumped from
UV **80.0** to **20.5**: half the density, out of phase by 59.5 UV units. The tiles now use
`GetUVCoordinates(Vx, Vz) * Setup.SETTINGS.UV_SCALE`, the same function as the main plane, and their
colour is `Helper.WATERLINE_COLOR` instead of TROUGH. The seam offset is now **78.0 UV units** — an
exact integer, because a tile sits 1872 studs away and 1872 / 24 = 78 — so the pattern is continuous
across the seam and **across tile borders** as well (checked live: every tile reports
`uv(2.00, 80.00)`; the main plane reports `40.67`–`41.00` at local 0).

This is UV *mapping*, not texture work: no texture, colour or wave number changed.

## 4. The wave field stops at ~700 studs and the horizon is a flat plate — RECORDED, NOT CHANGED

The main plane is 1872 × 1872 studs, but a chunk is only computed when its centre is within
`MaxChunkRenderDistance = 800`. **Culling a chunk does not hide it** — the whole plane is one
MeshPart, so every culled vertex is still drawn, frozen at whatever position it was last written
(zero, for vertices that were never written at all). Measured live:

| radius (studs) | moving vertices (|Y| > 0.05) |
|---|---|
| 100 | 212 / 221 |
| 200 | 620 / 656 |
| 300 | 386 / 412 |
| 400 | 303 / 388 |
| 500 | **154 / 319** |
| 600 | 76 / 189 |
| 700 | 56 / 195 |
| 800 | 34 / 193 |
| 900 | **2 / 728** |

Rendered position vs the analytic surface at the same frame (rest position snapped back to the
12-stud grid, so the horizontal Gerstner displacement does not pollute the comparison):

| radius | mean abs error | max | vertices over 1 stud |
|---|---|---|---|
| 0–100 | 0.12 | 1.51 | 3 % |
| 100–200 | 0.55 | 3.02 | 17 % |
| 200–300 | 0.84 | 3.94 | 29 % |
| 300–400 | 0.92 | 4.05 | 34 % |
| 400–500 | 0.94 | 4.16 | 37 % |
| 500–600 | 0.95 | 4.13 | 34 % |
| 600–700 | 1.11 | 4.11 | 44 % |
| 700–800 | 1.10 | 4.22 | 41 % |
| 800–900 | 1.20 | 4.48 | 44 % |
| 900–1000 | 1.38 | 4.45 | 56 % |

At +900 studs the true wave was **-1.77 studs** while the mesh was flat. The 0.12-stud floor inside
100 studs is one frame of sampling staleness (the probe reads the mesh after the write, the analytic
value is computed at read time), so read the *shape* of that table, not its floor.

So the sea beyond ~800 studs is a flat plate at Y = 25 with a chunk-quantised boundary — 2.3 px of
step at 800 studs (0.0036 rad at a 718 px/rad viewport), i.e. subtle, but the whole far field is the
wrong surface on purpose.

**Why it was not changed:** covering the whole plane means computing 21 % more chunks and writing the
~46 % of vertices that were previously skipped. That is a straight frame-time cost and the trade
belongs to a budget decision, not to this pass. The honest options are (a) raise
`MaxChunkRenderDistance` to ~1400 and pay for it, (b) keep the cull and reduce the plane so the flat
ring is smaller, or (c) leave it. It is also worth renaming the setting: it does not control
rendering.

## 5. The whirlpool is a 170-stud hole that only the mesh knows about — RECORDED, NOT CHANGED

This is the largest disagreement between what the water *looks* like and what it *is*, and it sits
314 studs from spawn. Live, in the client's mesh:

| measurement | value |
|---|---|
| zone | `Whirlpool`, origin `313.61, 35.5, 292.16`, radius **150** |
| its authored values | `TangentSpeed -300`, `RotSpeed 15`, `DownwardForce 250`, `Scale` hardcoded 15 |
| mesh world Y within 160 studs of it | **-169.1 … 29.0** (repeat: -171.1) |
| vertices below -20 studs | 10, 18 (two probes) |
| the sea's own envelope | 4.7317 studs |

`Gerstner.GetVortexTransform` produces `DownwardForce / (Distance / Scale + 1)` studs of downward
displacement: **-250 studs at the centre**, -125 at 15 studs out. That is 53× the wave envelope and
36× the measured sea's reach, so the whirlpool is a funnel deeper than it is wide, with the UV
rotation on top of it (the module's own comment admits the UV distortion at its border).

**It is mesh-only.** `GetVortexTransform` is called from exactly one place — `ParallelWorker`, the
ocean mesh. Nothing computes a height from it: `WaveFloat` never sees it, and both ship scripts
actively skip whirlpool zones (`if currentZone.Type ~= "Whirlpool"`). So a hull, a swimmer or a
floating prop crosses the visible funnel at wave height, on flat water, inside a 170-stud pit.

Both the depth and the physics gap are content decisions: `DownwardForce` is a `NumberValue` inside
`Workspace.Whirlpool` (place content, not in `src/`) and `Scale = 15` is a literal in the place's
`Whirlpool` script. Changing either changes a designed feature, so nothing was changed. If the funnel
is what looks wrong, the two levers are `DownwardForce` (depth) and `Scale` (how fast depth falls off
with distance), and the third option is to make the physics read the same vortex so the pit is real.

## 6. Optimisation: distance-graded write cadence, and a cheaper UV scroll

Both changes are in `Settings.PERF` + `ParallelWorker`.

1. **`UV_WRITE_EVERY` 3 → 6.** A UV write measured ~7× a position write (5.7 µs vs 0.82 µs, one
   session each — a lead, see `03-perf.md`). The scroll is 1/12 UV per second, so at 60 fps a
   6-frame cadence steps the texture 0.0083 UV units — about 0.2 studs of travel per write.
2. **Graded cadence.** `FAR_WRITE_DISTANCE = 400` / `FAR_WRITE_EVERY_BEYOND = 2`: low-detail
   vertices within 400 studs of the camera are still written every frame, beyond it every 2nd. The
   old beat was 3 frames everywhere, which is what `ec336b8` removed as visible stepping; 2 frames at
   the *same* sea is a finer step than the 3-frame one that was rejected, applied only where the
   wave is far away.

**Measured step per write in the 400–800 stud band** (shipped settings, 30 vertices watched over 89
frames, live mesh): 58 non-zero steps, **mean 0.0561 studs, max 0.1087**; converted through the
viewport (953 × 878, FOV 70 → 627 px/rad) that is **0.070 px mean, 0.142 px max**. Sub-pixel, and
about 5 % of the ~1.1-stud error that band already carries against the analytic surface (§4).

**No frame-time claim is made.** The write-count A/B did not converge. Four sessions, camera pinned
to `0, 60, 400` in each (`CameraType = Scriptable`, verified still pinned at read time):

| variant | session 1 | session 2 | session 3 |
|---|---|---|---|
| A — old cadence (UV 3, no grading) | 197 writes/worker, 0.174 ms | 171.5, 0.135 ms | — |
| B — shipped (UV 6, graded 2) | 215, 0.177 ms | 202, 0.158 ms | **149**, 0.131 ms |

B came out *above* A twice and below it once, which is impossible from these two changes alone (B
writes a strict subset of A's vertices). The counter is `for _ in Computations do WriteCount += 1`
— entries per frame, i.e. vertices, not API calls — so it is not measuring the thing either. The
session spread (149–215 on identical settings and an identical camera) is larger than the effect, so
the honest statement is: **the direction is expected, the magnitude is unmeasured, and Studio's
frame-time noise here is the reason `03-perf.md` asks for two agreeing sessions.** The visual
justification for the change stands on the step measurement above, which is independent of frame time.

---

## 7. What could not be verified

- **Whether any of this looks right.** `capture_viewport` does not draw water, so every colour and
  seam claim above is a number about the mesh, not a picture. The user's eye is the instrument.
- **The write-count / frame-time effect of §6** — see the table; the environment did not cooperate.
- **The horizon plate in pixels** — the 2.3 px figure at 800 studs is arithmetic from the measured
  step, not a screenshot measurement.
- **When zones reach the ocean.** One early probe in this session series saw no whirlpool in the mesh
  at ~12 s, and every probe since has seen it from the first seconds. The zone-spawning scripts live
  in the place (`Workspace.Whirlpool`, `Workspace.RoughSeaArea`), not in `src/`, so I could not read
  their client path. The two failure modes I tested and **ruled out**: the zone list is identical on
  server and client (2 zones, same `SpawnedAt`), and a stationary camera from t = 2 s still gets the
  funnel, so it is not the "only tagged when the plane re-snaps" path.

## 8. What to try in Play

1. **Look at the sea against the sky**, calm and rough. Crests should now read lighter than troughs
   all the way to the horizon instead of the sea being one dark colour with a lighter ring at 400
   studs. If it now looks *too* contrasty, the single knob is `Helper.HeightToBlend`'s `* 0.5`
   (a factor below 0.5 compresses the range around the waterline).
2. **Stand on a boat and look at the far water.** The tiles at ~936 studs should carry the same
   texture scale as the water beside you — previously it halved at that line.
3. **Swim to the whirlpool** (314 studs east of spawn). Expect a 170-stud funnel with rotating
   texture that your character and boat pass straight over. If that is the "conflicting" water,
   `DownwardForce` (250) is the depth lever and `Scale` (15, hardcoded in the place's script) is the
   falloff lever — say which way you want it and I will change them.
4. **Fast pan** along the water surface looking for stepping in the 400–800 stud band. Measured at
   0.07 px mean / 0.14 px max, so it should be invisible; if it is not, the knob is
   `Settings.PERF.FAR_WRITE_EVERY_BEYOND` (set it to 1 to get the previous behaviour back exactly).
