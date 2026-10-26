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
| S1 | Far-vertex write budget (`FAR_WRITE_EVERY=3`) | **Present and armed, not yet measured.** Still live in `Settings/init.luau:164`. Needs an in-Play client probe; `capture_viewport` cannot judge water. | §4 |
| S3 | Sea-state term inside the far-vertex lerp | Not yet measured. Same dependency (needs in-Play client vertex reads). | §4 |
| S4 | Detail boundary at `MeshDetailDistance = 120` | Not yet measured. | §4 |
| S5 | Zone multipliers in one path only | **Checked by reading, no mismatch found.** Both paths take `PhaseMultiplier`, `SpeedMultiplier`, `AmplitudeMultiplier`; `WaveFloat.HeightAt` reads them into `phase/speed/amplitude` and passes the same triple to `ComputeTransform`, which the mesh path also calls. | §5 |
| S6 | Stale far chunks past 800 | Not yet measured; belongs with the seam work in prompt 04. | §4 |

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

## 4. S1/S3/S4/S6 — still open, and why

These are all *visual* jitter claims about the far-vertex path. Measuring them means reading
`EditableMesh` vertex positions frame-to-frame from a **client** probe, in windows under 15 s
(the client RPC limit). That is the right measurement and it is still to do — the numbers in this
file do not yet support or reject S1.

What *is* established: `FAR_WRITE_EVERY = 3` and `UV_WRITE_EVERY = 3` are live
(`Settings/init.luau:164-165`, consumed at `ParallelWorker.client.luau:104-105`), so far vertices
provably update on a different frame cadence from near vertices. A 3-frame cadence at 60 fps is a
20 Hz stepping on the far field; whether it reads as a spasm at the amplitudes in play is the open
question.

**A2 (no periodic 3-frame pattern over a calm→rough transition) is NOT met yet.** Do not read this
document as closing prompt 02.

---

## 5. S5 — checked, no mismatch

`WaveFloat.HeightAt` and the mesh path both apply the zone triple. `HeightAt` reads
`zone.PhaseMultiplier`, `zone.SpeedMultiplier`, `zone.AmplitudeMultiplier` (defaulting each to 1)
and passes `phase, speed, amplitude` — in that order — to `Gerstner.ComputeTransform`, which is the
same function `ParallelWorker` uses. `HeightLookup.Lookup` takes the multipliers in a **different
order** (speed, phase, amplitude), and `WaveFloat` already documents and translates that. No defect.

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
