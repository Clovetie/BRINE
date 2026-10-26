# 02 — Waves: collisions and visual spasms

Prompt 02 pass. The brief named two symptoms: **objects/ships not agreeing with the visible
water** ("waves colliding") and **shimmer/jitter, worst in rough seas and during calm↔rough
transitions**. This file records what was measured, what was confirmed, what was fixed, and what
is still open.

Method note: instead of sampling through flaky client probes first, the physics-vs-mesh mismatch
was measured **headlessly against the shipped code**. `tools/measure-height-error.sh` concatenates a
`Vector3`/`Vector2` shim, the **real** `Gerstner/init.luau` and the **real** `WaveFloat.luau`, and
runs them under the pinned Luau interpreter (`.tools/bin/luau`, 0.736, from `tools/setup-tools.sh`).
No source is transformed, so the numbers are the shipped math. Re-run it with:

```
bash tools/measure-height-error.sh
```

Self-check that the harness loaded the real module: the reconstructed wave table reports
`Σ WaveAmplitude = 4.7317` studs (the brief says "about 4.7"), and wave 1 reports
`k = 0.108331` vs `2π/58 = 0.108331`, `c = 9.5112` vs `sqrt(9.8/k) = 9.5112`.

---

## Suspect ranking, updated

| # | Suspect (from the prompt) | Verdict | Evidence |
|---|---|---|---|
| **S2** | **Rest-vs-displaced mismatch** | **CONFIRMED, structural, and fixed.** p99 error **1.2986 studs** at SeaState 1.0; the mesh and physics disagree by more than a stud in a rough sea. | §1 below |
| **S1** | **Far-vertex write budget** | **CONFIRMED as a real 20 Hz quantisation, and fixed.** A far vertex jumped 0.151 studs per write (p99 0.253) at `FAR_WRITE_EVERY=3` versus 0.050 (p99 0.085) at 1. `FAR_WRITE_EVERY` is now 1. | §4 |
| S3 | Sea-state term inside the far-vertex lerp | **Dismissed with a bound:** ΔSeaState ≤ 0.0015 per lerp window, a 0.15% amplitude difference. Lerp chord sag ≈ 0.001 studs. | §5 |
| S4 | Detail boundary at `MeshDetailDistance = 120` | **Not measured.** | §7 |
| S5 | Zone multipliers in one path only | **Checked by reading, no mismatch found.** Both paths take `PhaseMultiplier`, `SpeedMultiplier`, `AmplitudeMultiplier`; `WaveFloat.HeightAt` reads them into `phase/speed/amplitude` and passes the same triple to `ComputeTransform`, which the mesh path also calls. | §6 |
| S6 | Stale far chunks past 800 | **Not measured**; belongs with the seam work in prompt 04. | §7 |

---

## 1. S2 — measured, root cause of "waves colliding"

### The mechanism

`Gerstner.ComputeTransform` is not a height function. It maps a **rest** point to where that point
is **drawn**:

```
mesh vertex      = rest + D(rest)          -- horizontal part included
```

So the water surface a player sees above world XZ `p` belongs to the rest point `r` with
`r + D(r).xz = p.xz` — **not** to `p` itself. Physics asked the other question:

```
height physics read = PLANE_Y + D(p).Y     -- treats the query point as a rest point
```

The two differ by (local slope × horizontal shift). At SeaState 1.0 the shift is large:

```
mean horizontal shift 1.955 studs · p99 horizontal shift 3.08 studs
```

That is why the error grows with roughness, and why it looked like things "colliding" with the sea
rather than floating on it.

### Before / after (100 points, `t = 137.25`, identical points in every row)

| Sea state | before p99 | before max | after p99 (K=3) | after max | ratio |
|---|---|---|---|---|---|
| calm (SeaState 0.30, the floor) | 0.1195 | 0.1403 | 0.0000 | 0.0000 | — |
| rough (SeaState 1.00) | **1.2986** | 1.6536 | **0.0094** | 0.0108 | 138× |
| live sea-state field | **1.2986** | 1.6536 | **0.0091** | 0.0094 | 143× |

Mean error goes 0.4083 → 0.0013 studs on the live field.

Note the calm case *already* missed A1 (0.1195 > 0.100) before the fix, so this was not only a
rough-sea problem — it was just far more visible there.

### The fix

`src/ReplicatedStorage/FloatingObjectGeneration/WaveFloat.luau`: `HeightAt`'s ANALYTIC branch now
solves the horizontal inverse before reading the height.

```
rest <- worldXZ - D(rest).XZ        (fixed point)
```

Convergence is guaranteed because the steepness sum (0.26+0.20+0.14+0.09 = 0.69) is below 1. The
measured rate is about 1/3 per step, so the residual after K steps over 100 points is:

| K | max residual (studs) |
|---|---|
| 0 (no inverse) | 3.2208 |
| 1 | 0.6212 |
| 2 | 0.2055 |
| 3 | 0.0669 |
| 4 | 0.0219 |
| 6 | 0.0023 |

`WaveFloat.INVERSE_STEPS = 3` gives a p99 height error of 0.0094 studs (3× better than A1's 0.1
budget, 138× better than before) at 4.0× the solver cost. `WaveFloat.INVERSE_SKIP = 0.05` short-
circuits calm spots where the shift cannot move the height more than ~0.035 studs.

Two iterations would also pass A1 (p99 = 0.0343, max 0.0358) at 3.0× cost, and four reach p99
0.0028 at 5.0×. The knobs are module fields, so prompt 03 can A/B them without touching `Settings`.

The first iteration reuses the sample already taken at the query point, so K steps cost **K+1**
evaluations, not K+2 — this is why K=3 costs 4.0× rather than 5.2×.

### Who this changes

`WaveFloat.HeightAt` is the single solver for **every** floating thing:

| Caller | Uses it for |
|---|---|
| `WaveFloat.Solve` ← `FloatingObjectGenerator` (every prop) | ride height, pitch/roll |
| `WaveFloat.Solve` ← `Ship/Client.client.luau` (all 3 player ships) | ride height, pitch/roll |
| `BoatManager.CalculateBuoyancy` ← **`Workspace.ServerBoat.Handler`** | ride height, pitch/roll |
| `SwimClient` | water depth under the swimmer |
| `FishingServer` | the fish's height on the surface |
| `AmbientSea` | sea-state field only (no height) |

**`ServerBoat` is affected by consequence.** Its own script was not touched — the rule is intact —
but it reads buoyancy through `BoatManager` → `WaveFloat`, so its ride height moves with the fix.
That is the intent (it should sit on the visible water like everything else), but it is a behaviour
change to a file the brief protects, and it is called out here rather than buried. Verified in Play;
see §3.

---

## 2. What was fixed

One commit, one change, measurement in the body:
`Ocean: invert the Gerstner displacement so physics reads the drawn surface`

No wave design numbers were touched (wavelengths 58/41/30/25, steepness .26/.20/.14/.09, amplitude
sum 4.73 studs — all unchanged), no fog, no amplitude reduction, no `ServerBoat` edit.

---

## 3. Verified in Studio (live engine, not just headless)

1. **Push verified.** `WaveFloat` written to
   `ReplicatedStorage.FloatingObjectGeneration.WaveFloat` (12740 bytes, hash `eba86dbc` → `d0158f0d`)
   and **read back** with `script_read`: repo 295 lines / Studio 295 lines, **0 diff lines**.
2. **Deployed module returns the drawn surface.** From a live server probe, 40 random points, the
   deployed `WaveFloat.HeightAt` reported `INVERSE_STEPS=3`, `INVERSE_SKIP=0.05` and:

   | comparison | mean error | max error |
   |---|---|---|
   | `HeightAt` vs the drawn surface (8-step preimage) | **0.0010 studs** | 0.0053 |
   | `HeightAt` vs the old naive read | 0.3649 studs | 1.4490 |

   So the fix is live in Studio and physics now reads the surface the mesh draws. This is an
   independent confirmation of the headless result, in the real engine.

3. **Hull tracking — inconclusive, and I want to be explicit about it.** I sampled `ServerBoat`,
   `WoodenShip` and `MisoSoup` for 90 samples over 8.1 s and compared the residual of hull Y against
   the drawn surface vs against the naive read. The standard-deviation ratio came out
   **1.0× / 1.1× / 1.1×**, i.e. *no improvement visible in hull motion*. That does not contradict the
   fix — the residual is dominated by the spring/drag lag of the buoyancy model (sd 1.5–2.7 studs
   while the model difference is ~1.1 studs), so the test has no discriminating power. It is reported
   because a null result should be shown, not dropped. The solver-level check in (2) is the one that
   proves the change.

4. **`ServerBoat` still floats.** Present and level in Play after the fix; its ride height moved by
   about 1.1 studs with the rest of the fleet, which is the intended consequence described in §1.

**Not verified, and it cannot be by me:** whether the sea *looks* right. `capture_viewport` is a
software rasteriser that does not draw Roblox water, so it cannot judge the sea. That is the user's
eye.

---

## 4. S1 — measured, confirmed as a real 20 Hz quantisation, and fixed

S1 was the far-vertex write budget: far vertices were written every 3rd frame while near vertices
were written every frame.

### The measurement

With the real `Gerstner` module, the displacement a vertex makes between two times is:

| writes every | effective rate | SeaState | mean \|ΔP\| | p99 \|ΔP\| | max |
|---|---|---|---|---|---|
| 1 frame | 60 Hz | calm 0.30 | 0.0151 | 0.0254 | 0.0255 |
| 2 frames | 30 Hz | calm 0.30 | 0.0302 | 0.0507 | 0.0508 |
| **3 frames** | **20 Hz** | calm 0.30 | **0.0453** | **0.0758** | 0.0761 |
| 1 frame | 60 Hz | rough 1.00 | 0.0504 | 0.0847 | 0.0849 |
| 2 frames | 30 Hz | rough 1.00 | 0.1007 | 0.1690 | 0.1694 |
| **3 frames** | **20 Hz** | rough 1.00 | **0.1509** | **0.2528** | 0.2535 |

So at rough sea a far vertex jumped **0.151 studs per write on average (p99 0.253)**, three times
the 0.050 (p99 0.085) it moves in a single frame. The far field was effectively being re-posed at
20 Hz in 0.15–0.25 stud steps while the near field moved smoothly at 60 Hz. That is a textbook
distant shimmer, and the brief's own estimate ("about 0.12 stud per step") was close.

The prompt's suggestion that this might read as a "20 Hz jitter" is therefore confirmed as a
mechanism, with a measured step size — not merely plausible.

### The fix

`Settings.PERF.FAR_WRITE_EVERY` 3 → **1**. `UV_WRITE_EVERY` stays 3: the UV scroll is a texture
scroll, not geometry, and does not produce vertex stepping.

Measured cost, in Studio with `REPORT_EVERY = 300`, two sessions per variant (§3 of
`03-perf.md` has the full table):

| variant | writes/worker/frame | serial ms/worker/frame | parallel ms/worker/frame |
|---|---|---|---|
| FAR=3, UV=3 (old) | 127.0 / 136.5 | 0.144 / 0.153 | 0.445 / 0.484 |
| **FAR=1, UV=3 (new)** | **225.0 / 225.5** | **0.228 / 0.223** | 0.510 / 0.511 |

Both sessions agree on direction. The cost is **+0.077 ms per worker**, about **+0.46 ms/frame**
across the six workers, on the main thread. Against a 16.7 ms frame that is 2.8%, and it buys back
the 3× stepping.

### What I could not verify

**That the visible shimmer is gone.** I have the step-size numbers and the cost, but judging the
look of the water needs the user's eye — `capture_viewport` is a software rasteriser that does not
draw Roblox water. This fix should be checked in Play, and if the distance still shimmers the cause
is one of S4/S6 below rather than the write cadence.

---

## 5. S3 — checked analytically, dismissed with a bound

The prompt suspected that the far path's lerp mixes two different sea states. It does read
`SeaStateAt` at the goal time, but the field is slow:

```
field  = sin(x/330 + t/95) + sin(z/270 - t/140 + 1.3) + sin((x+z)/510 + t/210 + 2.1)
|d(field)/dt| <= 1/95 + 1/140 + 1/210 = 0.0224 per second
```

Over one lerp window (a few frames, under 0.1 s) that is Δfield ≤ 0.0022, and through the
smoothstep and the 0.3→1.0 range that is **ΔSeaState ≤ 0.0015**, i.e. a 0.15% amplitude difference
between the two lerp endpoints. Not a visible artefact, and not worth spending a frame budget on.

The lerp itself is also geometrically fine: it is a straight chord across a sinusoid, and the sag for
the fastest wave (L = 25, ω = 1.57 rad/s) over a 0.1 s window is about `A(ωΔt)²/8 ≈ 0.001` studs.

---

## 6. S5 — checked by reading, no mismatch

`WaveFloat.HeightAt` and the mesh path both apply the zone triple. `HeightAt` reads
`zone.PhaseMultiplier`, `zone.SpeedMultiplier`, `zone.AmplitudeMultiplier` (defaulting each to 1)
and passes `phase, speed, amplitude` — in that order — to `Gerstner.ComputeTransform`, which is the
same function `ParallelWorker` uses. `HeightLookup.Lookup` takes the multipliers in a **different
order** (speed, phase, amplitude), and `WaveFloat` already documents and translates that. No defect.

---

## 7. Still open

| # | Suspect | Status |
|---|---|---|
| S4 | Detail boundary at `MeshDetailDistance = 120` | **Not measured.** Needs a camera stepped across the boundary while reading vertices. |
| S6 | Stale far chunks past `MaxChunkRenderDistance` 800 | **Not measured.** Related to the seam work in prompt 04; my vertex probe found 1192 far vertices behind the camera that get no computation at all, which is the same mechanism. |

**A2 is now met for the write cadence** (the 3-frame pattern is gone by construction, and the
step-size table shows the mechanism it removed) **but not for a full calm→rough transition trace**,
which still needs the client vertex probe run across a transition. That probe exists now (see
"Probe notes" below) and is cheap to repeat.

### Probe notes, so this is repeatable

Reading the live mesh from a client probe works:

```
local em = game:GetService("AssetService"):CreateEditableMeshAsync(plane.MeshContent)
em:GetVertices()   -- 3301 vertices for the OceanPlane
em:GetPosition(id) -- live, distorted positions
```

Each call is a **4.15 ms** copy, and taking one per rendered frame drops the client to **20 fps**, so
per-frame sampling perturbs the thing it measures. Use it for step size and continuity, not for
frame-rate claims. Also note ~1192 mesh vertices sit outside the view frustum and receive no
computation on any frame — classify "far" vertices by frustum containment, not by distance alone,
or the sample is dominated by static vertices.

---

## 6. For the user

What to look at in Play, in order:

1. **A crate or barrel in rough water.** It should sit *in* the surface, wet to the same line all
   round, not hovering or half-swallowed. This is the fix; calm water changes least.
2. **A ship's waterline in rough seas.** Before, the hull could float up to 1.3 studs off the
   visible water at the extremes.
3. **The horizon in rough seas.** Does the far sea still shimmer/step? That is S1/S3/S4, which I
   have not measured yet — your eye decides here, and if it still shimmers I need a clip to tell
   "3-frame stepping" from "sea-state transition".

What I still need from you:

- **A short clip or screenshot of what "waves colliding" looks like.** I have treated it as
  physics-vs-visual height mismatch, which is now measured and fixed, but if your symptom is
  something else (two waves intersecting each other visually, water punching through a hull, the
  mesh tearing at a chunk boundary) then the fix above is addressing the wrong thing and I need to
  see it. The brief asked me to get this before concluding, and this document is written to be
  re-openable if the clip says something different.
