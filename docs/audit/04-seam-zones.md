# 04 — Seam, zones, and the two unexplained collision symptoms

Covers the prompt 04 seam/immersion questions plus the two "colliding" symptoms that
`02-waves-findings.md` did not explain: **waves visually intersecting each other** and **water
punching through hulls**.

Everything here is either a measurement from a script that runs the shipped modules, or a read of
the live DataModel. Where I could not conclude, it says so.

---

## 1. Waves intersecting each other: measured, NOT a Gerstner fold

### The question

A Gerstner surface `p -> p + D(p)` is only a valid surface while its horizontal Jacobian

```
J = [ 1 + dDx/dx   dDx/dz ]
    [   dDz/dx   1 + dDz/dz ]
```

has `det J > 0`. Where `det J <= 0` the map folds: two rest points land on the same world XZ, the
triangles invert, and the render shows wave crests crossing through each other and cusps tearing.
That is the only way a *pure* Gerstner field can make waves look like they intersect.

Re-run: `bash tools/measure/jacobian.sh`

**Method note, because I got this wrong first.** My first version derived the Jacobian by hand and
multiplied an extra amplitude factor into the displacement term. That inflated the fold estimate by
1.3–2.4× and made a harmless zone look broken. The tool now differentiates the **shipped
`Gerstner.ComputeTransform` by finite differences** (`h = 0.05` studs) and prints
`|numeric − analytic|` as a standing cross-check, so the two methods have to agree before any number
is believed.

### Result

| Case | min det J | folds |
|---|---|---|
| calm (SeaState 0.30) | **+0.8054** | 0 / 73 205 |
| rough (SeaState 1.00) | **+0.4307** | 0 / 73 205 |
| live sea-state field | **+0.4399** | 0 / 73 205 |
| uniform amplitude ×1.5 | +0.2274 | 0 |
| uniform amplitude ×2.0 | +0.0843 | 0 |
| uniform amplitude ×2.5 | −0.0015 | **1 / 41 405** (grazing, one point) |
| **the shipped `RoughSeaArea` zone** | **+0.1729** | **0** (sea state 1.00) |
| same zone, sea state 0.30 | +0.6849 | 0 |

Cross-check agreement: `|numeric − analytic|` max was 5.2e-4 (calm), 1.9e-3 (rough) and 1.4e-2 (live
field, where the sea-state *spatial gradient* is a real term my analytic form does not include).

**Conclusion: the shipped ocean never folds.** Not in calm, not in rough, not inside the rough-sea
zone, at any of five sample times across the sea-state field's period. Waves crossing each other in
the render are therefore **not** a self-intersection of the wave field.

### So what is making waves look like they intersect?

Three candidates remain, in order of how likely they are to be what the user is seeing:

1. **Normal crest crossing.** Four waves on different headings (0.92/0.38, −0.35/0.94, 0.71/−0.71,
   −0.96/−0.27) genuinely produce an X-shaped interference pattern. This is the intended look of a
   multi-directional Gerstner sea, but with no foam, no whitecaps on the crossover and a flat
   `SurfaceAppearance` it can read as "broken waves" rather than "crossing swell". **`WHITECAP_HEIGHT
   = 6` is configured but the whitecap path is not visible in the shipped look** — worth the user's
   eye.
2. **The far-field write cadence** — already fixed in `ec336b8`. That produced 0.15–0.25 stud
   stepping at 20 Hz, which reads as shimmer/tearing at distance, not as crossing crests.
3. **Chunk-boundary discontinuities** — not yet measured. `MeshDetailDistance = 120` splits chunks
   into full-detail and lerped paths by `DistanceToChunk`, so two neighbouring chunks either side of
   that radius update by different methods. See §5.

I am not closing this symptom. It needs the user's clip, and if the clip shows an X pattern in open
water it is case 1 and the fix is a look decision (foam on crossovers), not a bug fix.

---

## 2. Water through hulls: measured per hull

`WaveFloat.HeightAt` (now inverted, prompt 02) sampled at each hull's `Main` over 50 samples / 6 s,
against each hull's part geometry.

| Hull | `Main` Y range | water mean | water vs `Main` top | parts straddling the waterline |
|---|---|---|---|---|
| `ServerBoat` (reference) | 21.63 – 25.01 | 23.43 | −1.58 (cut properly) | 2 |
| `WoodenShip` | 19.39 – 22.77 | 26.51 | **+3.74 above** | 3 |
| `MisoSoup` | 25.26 – 27.23 | 24.41 | −0.85 (clear of water) | 4 |
| `Boathouse` | 68.00 – 71.38 | 22.71 | +48.7 | **0** |

Readings:

- **`ServerBoat` is the only hull whose reference part is cut by the sea the way a hull should be**
  (water 1.6 studs below its `Main` top, i.e. inside the body). This is the ship the brief protects,
  and it is behaving.
- **`WoodenShip` sits ~3.7 studs deep relative to its `Main`** — the sea plane is above the top of
  its buoyancy reference part. Given it is also the hull running a **stale client script** (D-01),
  this is consistent with "WoodenShip's minimum sink is poor": it is the one hull whose buoyancy
  code in Studio is a different, older program.
- **`MisoSoup` floats with `Main` entirely clear of the water** (0.85 studs) and its `Draft`
  attribute is **−7.3** while its siblings are +5.5 and +3.5. It is also 75 parts, the most complex
  hull. Negative draft may be deliberate for this hull or a sign error (D-13); the geometry alone
  cannot decide.
- **Freeboard is not the problem anywhere.** Every hull's highest part sits 34–60 studs above mean
  water, against a maximum crest of +4.73 studs (the wave amplitude sum). **No crest can reach any
  deck**, so "water through hulls" is not a wave-over-the-deck event on these models. If water is
  visibly punching through a hull, it is the hull sitting too deep (or a hull mesh with no bottom
  face), not the crest height.

---

## 3. `Boathouse` is not a broken ship — it is parked on the platform slab

This corrects D-12 and D-13 from the audit pass. The Boathouse appeared to "hover 46 studs above
the sea", which looked like a serious buoyancy bug. It is not.

Evidence:

- `Workspace.Part` (the protected platform slab) is **`size 121 × 230 × 98` at `16.16, −44.76,
  174.04`, so its top face is at `Y = 70.24`**. The Boathouse's `Main` bottom is at `Y = 68.00`, and
  `Workspace.Part` appears in its `GetTouchingParts()` list.
- The Boathouse is unanchored and has a live `Handler` + `Client`, but its **server
  `UnmannedBuoyancy` AlignPosition is `Enabled = false`** and still holds its creation-time value
  (`Y = 88.39`, the seat attachment's world position). That is exactly the airborne path in
  `Handler.server.luau`: `WaveFloat.Solve` returns `nil` because `depth = surfaceY − waterlineY =
  25.3 − 69.7 = −44.4`, far below `AIRBORNE_DEPTH = −0.5`. So the servo correctly refuses to drive a
  hull that is 44 studs clear of the water, and gravity + the slab hold it.
- A ray straight down from the Boathouse hits `Workspace.Part7` at `Y = 8.24`.

**So the Boathouse is a prop standing on the spawn platform, not a floating ship**, and
"the Boathouse bounces at draft 3.5" cannot be reproduced while it is parked there. It needs to be
put in water to be judged. Its `Draft = 3.5` is currently dormant.

### Leftover legacy movers on the hull — real, but dormant

While measuring this I found two constraints that the current code does **not** create:

| Object | Class | Target | Origin |
|---|---|---|---|
| `Workspace.Boathouse.Prim.BodyPosition` | BodyPosition | `0, 0, 0` | pre-rework handler |
| `Workspace.Boathouse.Prim.BodyGyro` | BodyGyro | — | pre-rework handler |

A `BodyPosition` whose goal is the **world origin** is a live hazard: if it were ever enabled it
would drag the hull toward `(0,0,0)` at massive force. It is off/inert today (the model is at
`Y ≈ 69.7`, not at the origin). Recommend deleting both from `Boathouse` (and checking `MisoSoup`,
which has a `Prim` too) — recorded as D-17 rather than deleted, because whether the hull should keep
a legacy `Prim` is a content decision.

---

## 4. Seam and fog: measured, and the hiding works

Read from a **client** probe in Play (fog is client-side, so it cannot be read in edit mode):

| Quantity | Value |
|---|---|
| Client `Lighting.FogStart` | **500.0** |
| Client `Lighting.FogEnd` | **880.0** |
| `Lighting.FogColor` | `0.7529, 0.7529, 0.7529` |
| `Atmosphere` | density 0.380, haze 1.000, offset 0.00 |
| Ocean planes | **9** (`OceanPlane` + 8 `SecondaryPlane`), each `1872 × 0.001 × 1872` |
| Plane positions | 3×3 grid, X ∈ {−1872, 0, 1872}, Z ∈ {−1584, 288, 2160} |
| Mesh local extent | ±936 (measured: vertex 1 at `−936, 0, −936`) |
| Farthest plane edge from origin | ~2808 studs |

The mesh's outer edge is at ≥1872 studs from the origin for any camera near the middle, which is
**2.1× the fog end of 880** — comfortably hidden. The 9 planes tile exactly at 1872 spacing with a
±936 half-extent, so adjacent planes meet with no gap. `MaxChunkRenderDistance = 800` stops
computation slightly before the fog end at 880; the last 80 studs are ≥90% fogged, so frozen chunks
there are not visible.

**Verified by numbers: the seam hiding is sound. Not verified: that the seam is invisible by eye.**
That is the user's call (and `capture_viewport` cannot render water).

---

## 5. Still open from this pass

| Item | Why it is open |
|---|---|
| "Waves intersecting" as a *look* decision | Fold ruled out. Remaining causes (§1) need the user's clip to tell apart. |
| S4 — `MeshDetailDistance = 120` boundary | Neighbouring chunks either side of the radius update by different methods. Not measured; needs a camera stepped across the boundary while reading vertices, which my probe can do but at 4.15 ms/frame. |
| S6 — stale chunks past 800 | Not measured; the fog analysis (§4) bounds its visibility to 80 studs of near-total fog, so it is low priority. |
| The two duplicated zone scripts (D-10) | `Workspace.RoughSeaArea.RoughSea` and `ServerStorage.OceanEvents.SeaStuff.RoughSeaArea.RoughSea` are byte-identical (hash `43676cc2`), same for the whirlpool pair (`9bf3cd18`). Both print "Added rough sea zone!" in the console, so **both are running**. Which one is authoritative is a content decision, so this is recorded, not deleted. |
| The `RoughSeaArea` zone's `AmplitudeMultiplier = 2.5` | Measured **safe** (min det J = +0.173, §1). Σ steepness × 2.5 = 1.725 is past the classic Σ Q ≤ 1 rule of thumb, but the zone's radial falloff and the phase alignment keep the surface valid. **No change needed** — recorded because it looks alarming and someone will "fix" it otherwise. |
