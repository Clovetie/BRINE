# 07 — Ships and physics

Play measurements, source fixes and diagnoses. `ServerBoat` is the physics reference and was not
touched (`git diff --name-only` over the whole branch names no boat file; the place's `ServerBoat`
still carries its original three legacy movers).

## 0. The prompt's ship list is stale — read this first

`07-ships-and-physics.md` measures `Boat`, `Boat1` and `Template`. **Those three models do not exist in
the place.** A live scan:

```
ServerBoat  parts=4   mass=1556   Main 9.0x3.4x45.0    pos(72.2,35.6,-70.8)
WoodenShip  parts=11  mass=2663   Main 12.7x3.4x88.0   pos(129.7,59.5,149.1)
MisoSoup    parts=75  mass=19565  Main 20.4x2.0x125.4  pos(15.4,56.0,313.4)
Boathouse   parts=29  mass=2757   Main 13.0x3.4x45.0   pos(87.2,83.1,174.8)
Boat / Boat1 / Template: MISSING
```

So the fleet is four hulls, not six, and every draft/sink number in the prompt's "Current state" table
that refers to `Boat`, `Template` or `Boat1` describes models that are not in the place. The values that
concern `WoodenShip`, `MisoSoup` and `Boathouse` are still meaningful. Nothing else in this document
depends on the old names.

There is also **no `Workspace.singletons` folder in the place**: the Rojo project maps
`src/Workspace/singletons/Ship` to one, but the place ships each carry their own copy of `Handler` and
`Client`. That is why a change to "the singleton" has to be pushed three times, and it is why a hull can
drift out of date on its own (D-01 in `01-defects.md` was exactly that).

---

## 1. A1 — the draft and sink table, re-measured

Method: Play, nobody seated (so the server's unmanned path runs), each hull moved at run time to open
water at a fixed XZ, dropped 40 studs above the surface, then sampled at 10 Hz. The reading is
`Main.Center.WorldPosition.Y` minus the analytic surface under the hull's own column
(`WaveFloat.HeightAt`, `ANALYTIC`, same clock the solver uses). Positive = the hull centre is above the
water. On a hull whose `Main` is 3.4 studs tall, `Main`'s top is `offset + 1.7` and its bottom
`offset - 1.7`.

Nothing was saved: the hulls were moved in the running session only.

| Hull | Main (X×Y×Z) | Mass | `Draft` | `SinkRestOffset` | offset, last 5 s (mean / min / max) | max \|vy\| |
|---|---|---|---|---|---|---|
| `ServerBoat` (reference, legacy handler) | 9.0×3.4×45.0 | 1556 | — | — | **+12.41** / +7.87 / +16.83 | 22.2 |
| `WoodenShip` | 12.7×3.4×88.0 | 2663 | 5.5 | −2.0 | **+0.88** / −1.13 / +3.21 | 26.1 |
| `MisoSoup` | 20.4×2.0×125.4 | 19565 | −7.3 | 2.4 | **+0.48** / −0.93 / +1.60 | 9.7 |
| `Boathouse` | 13.0×3.4×45.0 | 2757 | 3.5 | (none) | **+0.73** / −3.61 / +4.88 | 12.5 |

Same hull, 8 s later, to see the settled state rather than the splash-down:

| Hull | offset, 15→23 s (mean / min / max) | max \|vy\| |
|---|---|---|
| `WoodenShip` | +0.50 / −1.69 / +2.50 | 19.6 |

**Before the fix** (this session, same method, shipped code): `WoodenShip` settled at offset
**−4.00** (−7.30 … +0.63) at 15 s and still −3.44 at 23 s, i.e. its `Main` top was ~2.3 studs **under**
the water — the deck awash, which is the "sits deep" symptom in `01-defects.md` D-13.

### What the reference hull's row means

`ServerBoat` rides with its `Main` centre **12.4 studs above** the water — its hull bottom is 10.7
studs clear of the surface. That is the hover the user reported, and it is in the **reference** hull,
which is out of bounds. The per-hull `Draft` values on the other three (5.5, 3.5, and −7.3 on
`MisoSoup`) are not physical drafts; they are the ad-hoc offsets that were pulling each hull down
toward the water to compensate. Since the reference cannot change, the honest statement is: *the
fleet's waterlines were never consistent with the reference, and they now are not consistent in the
other direction either.* §3's fix removes a 15-stud error that was making this worse, but the absolute
waterline per hull is still a taste value set by `Draft`.

---

## 2. D-17 — the Boathouse's legacy movers were live, not inert

This corrects the earlier note that they were "inert today". Measured in edit mode before removal:

| Instance | Class | Live values |
|---|---|---|
| `Boathouse.Prim.BodyPosition` | BodyPosition | `Position = (0, 0, 0)`, `MaxForce = (0, 400000, 0)`, `P = 40000`, `D = 1200` |
| `Boathouse.Prim.BodyGyro` | BodyGyro | `MaxTorque = (200000, 0, 200000)`, `P = 70000` |
| `Boathouse.Motor.Steer` | BodyAngularVelocity | `AngularVelocity = (0, 0, 0)`, `MaxTorque = (0, 2011492.75, 0)` |
| `Boathouse.Motor.VectorForce` | VectorForce | `Force = (0, 0, 0)` (inert) |

`BodyPosition` has no `Enabled` property — if it is parented, it is on. So the Boathouse had:

* a **400 000-stud Y force pulling its `Prim` toward world Y = 0**, i.e. a permanent sink load of about
  74 % of the hull's own weight (2757 mass × 196.2 ≈ 541 000). Its `VectorForce` on `Motor` was
  zero-force junk;
* a **200 000 X/Z torque holding it rigidly upright**, fighting the wave pose the handler commands;
* a **2 011 493 Y torque holding yaw rate at 0**, i.e. a steering lock on a hull that is supposed to be
  drivable.

None of the four is referenced by any script: neither `Handler` nor `Client` in the Boathouse mentions
`Motor` or `Prim`, and no file in `src/` mentions them either. All four were removed. Read back:

```
WoodenShip | movers=0
MisoSoup   | movers=0
Boathouse  | Draft=3.5 EngineAccel=2.4 ... | movers=0
ServerBoat | (no attributes)               | movers=3   <- reference, untouched
```

This is very likely the whole of the "Boathouse still bouncing" note: a constant 400 000 down-force
plus a 200 000 upright torque against a servo with a 4× weight force limit is a forced oscillation, not
a tuning problem.

---

## 3. The real float bug: the servo goal was in the wrong frame

Diagnosis, in order of what each measurement ruled out.

1. `WoodenShip`'s unmanned `AlignPosition` (`UnmannedBuoyancy`) held a **steady 15.1-stud error** —
   goal `Position.Y` 24.5, its attachment sitting at 39.5 — for minutes, with `Enabled = true`,
   `Active = true`, and `MaxAxesForce.Y` = 4× the hull's weight. Destroying the servo made the hull
   free-fall 493 studs in 2 s, so the servo *was* the only buoyancy, and it was holding the hull with a
   15-stud error.
2. Reading the geometry explains the 15 studs: `WaveFloat.Solve` returns a **hull-centre** height
   (it is built from the four `Main.TopLeft/TopRight/BottomLeft/BottomRight` corner heights plus
   `rideHeight = Main.Size.Y / 2`), but `Handler` and `Client` both wrote it straight into
   `AlignPosition.Position`, and in `OneAttachment` mode that is a goal for the **attachment on the
   `VehicleSeat`**. On `WoodenShip` the helm sits **16.9 studs** above `Main.Center`. So the servo was
   commanded to bury the hull ~16 studs deeper than intended, saturated, and the hull only stopped
   because the anti-sink guard and the servo fought to a standstill — a permanent 15-stud error plus a
   steady sink load. `Draft = 5.5` was an attempt to paper over exactly this.
3. Confirmed by a controlled A/B with the handler disabled and a servo of my own: writing the centre
   height (`goal = targetY - draft`) leaves the error at **15.12**; writing the same goal **in the
   mover's frame** closes it to **3.14** and lifts the settled hull from −3.74 to **+0.97**.

The fix, in both `Ship.Handler` and `Ship.Client`:

```lua
local draft = Ship:GetAttribute("Draft") or 0
local goal = here.Y + ((targetY - draft) - Main.Center.WorldPosition.Y)
```

`here` is the mover attachment, so the hull centre now settles on `targetY - Draft` exactly as intended,
and `Draft` finally means "studs of draft", 1:1.

The guard's reference had the same frame bug in its default branch (`baseHeight - draft` is a
centre-space quantity compared against a mover-space height), so it now carries the same conversion:

```lua
reference = surface + (Ship:GetAttribute("SinkRestOffset")
    or (baseHeight - draft + (here.Y - Main.Center.WorldPosition.Y)))
```

Per-hull `SinkRestOffset` values are already mover-space ("where the hull rests relative to the sea
surface, measured at rest"), so they are used as-is.

Pushed to `Workspace.WoodenShip`, `Workspace.MisoSoup`, `Workspace.Boathouse` (`Handler` and `Client`
each) and read back byte-for-byte: 12415 / 11618 chars, `moverFrame=true` in all six.

---

## 4. Per-hull speed and steering (the user's direction)

Every hull read `ShipDrive.Defaults` directly, so a 125-stud, 19 565-mass floating island, an 88-stud
schooner and a boathouse all accelerated, turned and stopped exactly like a 45-stud sloop. New in
`ShipDrive`:

```lua
function ShipDrive.Resolve(ship: Instance): Tuning   -- Defaults + NUMBER attributes on the model
function ShipDrive.TopSpeed(tuning: Tuning): number  -- positive root of the drag balance
```

Any `Tuning` field can be overridden by a number attribute of the same name on the ship model, e.g.
`WoodenShip: EngineAccel = 6.6, MaxTurnRate = 0.23`. Both sides resolve it (the `Client` clones against
its own model, the `Handler` sits inside it) and both re-resolve on `AttributeChanged`. Attributes were
chosen as the surface because they can be edited on the live place in Studio and read back, which is
where the user's taste values live.

Values set in Studio (attributes, read back):

| Hull | `EngineAccel` | `ReverseAccel` | `BrakeAccel` | `LateralDamping` | `ThrottleSpool` | `MaxTurnRate` | `TurnReferenceSpeed` |
|---|---|---|---|---|---|---|---|
| `ServerBoat` (Defaults, reference) | 8 | 2 | 8 | 1.2 | 1.5 | 0.50 | 6 |
| `WoodenShip` | 6.6 | 1.7 | 7.0 | 1.4 | 1.2 | 0.23 | 8 |
| `MisoSoup` | 3.6 | 0.9 | 6.0 | 2.0 | 0.8 | 0.11 | 10 |
| `Boathouse` | 2.4 | 0.7 | 5.0 | 1.2 | 1.0 | 0.24 | 6 |

How they were derived, so they are not arbitrary:

* **Top speed** from the same drag balance the model uses,
  `EngineAccel = 0.08·v + 0.0067·v²`: 26 studs/s for the 88-stud schooner, 18 for the 125-stud island,
  14 for the boathouse. `DragLinear`/`DragQuadratic` are left at Defaults on all three, so the *feel* of
  coasting is the reference's and only the thrust differs.
* **Steering**: every hull's steady turn radius at its own top speed is ≈ **1.3 hull lengths**, which is
  the ratio the reference already has (58.2 studs of radius on a 45-stud `Main`). `MaxTurnRate` is
  therefore `TopSpeed / (1.3 · length)`.
* `ThrottleSpool`, `BrakeAccel`, `ReverseAccel` and `LateralDamping` scale with size: the island
  spools at 0.8/s and keels at 2.0, the boathouse spools at 1.0/s and brakes at 5.

Verified live in Play by requiring the shipped module and resolving each hull:

| Hull | top | turn | radius | engine | reverse | brake | keel | spool | refSpeed |
|---|---|---|---|---|---|---|---|---|---|
| `ServerBoat` | 29.1 | 0.50 | 58.2 | 8.0 | 2.0 | 8.0 | 1.2 | 1.5 | 6 |
| `WoodenShip` | 26.0 | 0.23 | 113.0 | 6.6 | 1.7 | 7.0 | 1.4 | 1.2 | 8 |
| `MisoSoup` | 18.0 | 0.11 | 163.3 | 3.6 | 0.9 | 6.0 | 2.0 | 0.8 | 10 |
| `Boathouse` | 13.9 | 0.24 | 57.8 | 2.4 | 0.7 | 5.0 | 1.2 | 1.0 | 6 |

Four different hulls, four different handling profiles, each read from its own attributes. The
offline harness `bash tools/measure/ship-tuning.sh` prints the same table plus acceleration and coast
curves, running the real `ShipDrive.luau` under plain Luau:

```
hull                                   top   0-90%    dist    turnR  turn/s   coast   cdist
ServerBoat (reference, Defaults)     29.10    6.27    99.7     58.2   0.500    9.63   124.5
WoodenShip                           25.98    6.90    97.4    113.0   0.230   10.18   118.2
MisoSoup                             17.97    9.13    88.9    163.3   0.110   11.92    97.5
Boathouse                            13.88   10.63    82.0     57.8   0.240   13.08    83.7
```

The reference's modelled 29.10 top speed matches its recorded live drive numbers (28.9 at 12 s), which
is the sanity check that the model is the same model.

---

## 5. A2 — "settles without bounce"

The prompt's proposed threshold (max vertical speed under 0.2 studs/s after 20 s) **cannot be met by any
hull on this sea**, including the reference: a hull that tracks a 2.4-stud-amplitude wave has a genuine
vertical velocity of 1–3 studs/s, and the reference `ServerBoat` measured 22.2 studs/s peak while
still moving at 15 s. Recording the threshold as met or failed against that number would be
meaningless.

What was measured instead, and what actually matters:

| Hull | offset span, last 5 s (15–20 s) | offset span, 8 s later (23–31 s) | note |
|---|---|---|---|
| `WoodenShip` | 4.34 studs | 4.19 studs | bounded; no growth |
| `MisoSoup` | 2.53 studs | — | tightest of the three |
| `Boathouse` | 8.49 studs | — | worst; still the loosest hull |

The hulls are **bounded**, not diverging: a span of 2–4 studs about a steady mean is riding waves, not
bouncing. The `Boathouse`'s 8.5-stud span was measured **after** D-17's 400 000-stud down-force was
removed, so it is no longer the forced oscillation; it is the loosest of the three because it has no
`SinkRestOffset` and its `Draft` 3.5 is a guess. Draft sweep on the Boathouse, 6 s settle each:

| `Draft` | offset mean | offset min / max | max \|vy\| |
|---|---|---|---|
| 3.5 | −1.57 | −4.23 / +2.36 | 8.3 |
| 0 | **+1.11** | −0.59 / +2.67 | 13.6 |

`Draft 0` gives the tighter band, so the Boathouse's 3.5 is too deep now that the servo is honest. Left
unchanged: with the frame fix in place, `Draft` is a clean 1:1 lever and this is a taste value the user
should set by eye (see §7).

### The 6 Hz vibration

Sampling every frame shows a real oscillation, not aliasing (position moves with the velocity):

```
dt=0.0167 mainY 25.1193 vy  -3.778 goal 37.96
dt=0.0125 mainY 24.8300 vy -10.318 goal 37.96
dt=0.0208 mainY 23.9874 vy -20.128 goal 37.96
dt=0.0542 mainY 24.6458 vy +19.594 goal 38.03
dt=0.0125 mainY 25.1334 vy  -9.836 goal 38.03
```

Note the `dt` column: the server was stepping between 12.5 ms and 54 ms while my probes were running,
i.e. 18–80 fps. `AlignPosition.Responsiveness = 12` is a per-second velocity gain, so a gain that is
well damped at 60 fps overshoots when a step is 54 ms long. The vibration appeared **only** in the
loaded Studio session and its amplitude is small (≈0.85 studs). I could not separate servo gain from
server load here, so this is recorded as an observation with its likely cause and **no change made** —
lowering `Responsiveness` on the strength of a frame-rate-stressed measurement would be exactly the
over-fitting mistake this audit keeps warning about. To settle it: run Play on an idle machine at a
steady 60 fps and look for the same trace.

---

## 6. A4 / A5 — reference untouched, guard behaviour

* **A4 (`ServerBoat` unchanged): PASS.** No file matching `boat` is named by any commit on this branch,
  and the live `ServerBoat` still has exactly its original three movers (`BodyPosition`, `BodyGyro`,
  `BodyVelocity` on the `VehicleSeat`) and no attributes.
* **A5 (climb and anti-sink with the current sea): partially re-checked.** The guard's code is
  unchanged. `ShipGuard` logic is frame-independent and its inputs were re-derived above; the one
  behaviour that changed is the guard's default reference, which now carries the mover-frame
  conversion. A fresh ship-on-ship climb run was **not** re-done this session (it needs two hulls
  driven into each other over ~12 s with the client driving one of them). The last recorded numbers
  stand: side control `Boat` 3.22, `WoodenShip` 3.35.

---

## 7. What to try in Play

1. **Board the `WoodenShip`.** It should sit with its `Main` bottom just at the waterline (offset +0.9 at
   the centre, so ~0.8 studs of `Main` submerged) instead of the deck being under water. This is the
   visible change of this pass.
2. **Adjust `Draft` on each hull in Studio** — it is now a 1:1 lever: +1 draft = 1 stud deeper. Values
   today: `WoodenShip` 5.5, `MisoSoup` −7.3, `Boathouse` 3.5 (0 measured tighter).
3. **Drive the three hulls back to back.** They should now feel like three different ships: the
   `WoodenShip` accelerates to 26 in ~7 s with a 113-stud turning circle, the `MisoSoup` takes 9 s to 18
   and turns on 163 studs, the `Boathouse` takes 10.6 s to 14 and turns on 58. Cross-check against the
   `ServerBoat`'s feel.
4. **Steer the `Boathouse`.** Before D-17 it had a 2 011 493-torque yaw lock; it should turn now.
5. **Watch for a fine vertical buzz** on the `WoodenShip` at high seas (§5). If it shows at 60 fps, the
   fix is `Responsiveness` in `Handler`/`Client`, and the number to try is 6.

## 8. What could not be verified

* **Ship-on-ship climb** was not re-run (A5, above).
* **The 6 Hz vibration** could not be separated from server load.
* **The `Client` (occupied) path**: every measurement here is the server's unmanned path. The frame fix
  is identical in `Ship.Client`, and `Ship.Client` is the same age as the handler, but the occupied path
  was not sampled. Boarding a hull is the check.
* **Absolute waterlines** are a taste call; the numbers say where the hulls are, not where they should
  be.
* `ServerBoat` cannot be judged at all without changing the reference: it hovers 12.4 studs up. If that
  is the look the user wants for the whole fleet, then the three hulls' drafts should come back up
  toward it, not the other way round.
