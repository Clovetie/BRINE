# Boat handler update

> **Status: implemented, and the code has since moved on from this document.** The buoyancy
> and mover setup described below lives in `src/Workspace/singletons/Ship/Client.client.luau`
> and `Handler.server.luau` (both solve the surface with
> `ReplicatedStorage.FloatingObjectGeneration.WaveFloat`; `BoatManager` is a compatibility
> adapter). The snippets below are kept as the reference for porting a *legacy* BodyMover
> boat — the reference `ServerBoat` still runs exactly that pattern, which is why they stay.
>
> **Read "Per-hull tuning" and "Buoyancy is a force, not a servo" (2026-10-27) first.** The
> vertical drive is no longer an `AlignPosition`: it is a spring-damper `VectorForce`, because
> the servo could not hold a hull without oscillating. The `Boat` model referenced throughout
> the old text **does not exist in the place** — the fleet is `ServerBoat` (reference, legacy
> handler), `WoodenShip`, `MisoSoup`, `Boathouse` — and there is no `Workspace.singletons`
> folder in the place: each hull carries its own copy of `Handler` and `Client`.

The supplied boat client is using `BodyPosition`, `BodyGyro`, and `BodyVelocity`.
Roblox marks all three legacy BodyMovers as deprecated; the supported replacements
are `AlignPosition`, `AlignOrientation`, and `LinearVelocity` respectively.
See the official [mover constraints guide](https://create.roblox.com/docs/physics/mover-constraints),
[AlignPosition](https://create.roblox.com/docs/reference/engine/classes/AlignPosition),
[AlignOrientation](https://create.roblox.com/docs/reference/engine/classes/AlignOrientation),
and [LinearVelocity](https://create.roblox.com/docs/reference/engine/classes/LinearVelocity).

Use this in the boat `Handler` before the simulation connection. It creates the
modern movers at runtime, so the old three movers can be removed from the
`VehicleSeat` in Studio:

```lua
local VehicleSeat = Boat:WaitForChild("VehicleSeat")
local PhysicsService = game:GetService("PhysicsService")

local function registerGroup(name)
    pcall(function()
        PhysicsService:RegisterCollisionGroup(name)
    end)
end

registerGroup("Boat")
registerGroup("BoatIsland")
PhysicsService:CollisionGroupSetCollidable("Boat", "BoatIsland", false)

-- Do not let island collision launch/climb the boat. Keep normal boat/player
-- collisions unchanged. Apply the island group to generated islands too.
local function markIsland(instance)
    if instance:IsA("BasePart") then
        instance.CollisionGroup = "BoatIsland"
    end
end
local map = workspace:FindFirstChild("Map")
if map then
    for _, instance in ipairs(map:GetDescendants()) do markIsland(instance) end
    map.DescendantAdded:Connect(markIsland)
end
for _, instance in ipairs(Boat:GetDescendants()) do
    if instance:IsA("BasePart") then instance.CollisionGroup = "Boat" end
end

local moverAttachment = Instance.new("Attachment")
moverAttachment.Name = "BoatMoverAttachment"
moverAttachment.Parent = VehicleSeat

local alignPosition = Instance.new("AlignPosition")
alignPosition.Name = "BoatBuoyancy"
alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
alignPosition.Attachment0 = moverAttachment
alignPosition.ApplyAtCenterOfMass = true
alignPosition.MaxForce = Boat.Main.AssemblyMass * workspace.Gravity * 6
alignPosition.MaxVelocity = 80
alignPosition.Responsiveness = 12
alignPosition.RigidityEnabled = false
alignPosition.Parent = VehicleSeat

local alignOrientation = Instance.new("AlignOrientation")
alignOrientation.Name = "BoatWaveOrientation"
alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
alignOrientation.Attachment0 = moverAttachment
alignOrientation.MaxTorque = Boat.Main.AssemblyMass * 5000
alignOrientation.MaxAngularVelocity = 8
alignOrientation.Responsiveness = 12
alignOrientation.RigidityEnabled = false
alignOrientation.Parent = VehicleSeat

local linearVelocity = Instance.new("LinearVelocity")
linearVelocity.Name = "BoatThrottle"
linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
linearVelocity.Attachment0 = moverAttachment
linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
linearVelocity.ForceLimitsEnabled = true
linearVelocity.MaxForce = Boat.Main.AssemblyMass * workspace.Gravity * 3
linearVelocity.VectorVelocity = Vector3.zero
linearVelocity.Parent = VehicleSeat
```

Replace the old mover setup and assignments in the `PostSimulation` callback:

```lua
-- Replace BodyVelocity.Velocity = ...
linearVelocity.VectorVelocity = if VehicleSeat.Throttle == 1
    then VehicleSeat.CFrame.LookVector * 30
    else Vector3.zero

-- Replace BodyPosition.MaxForce/Position. `Height` is the water target from
-- CalculateBuoyancy and `Orientation` is the wave orientation.
if Height ~= Vector3.zero then
    alignPosition.Enabled = true
    alignPosition.MaxForce = MAX_FORCE * (1 + (Depth / 10))
    alignPosition.Position = Height
else
    alignPosition.Enabled = false
end

alignOrientation.CFrame = CFrame.fromEulerAnglesXYZ(0, CurrentRotation, 0) * Orientation
```

`AlignPosition.Position` and `AlignOrientation.CFrame` are world-space goals in
one-attachment mode. That has a consequence for the buoyancy line above:
`BoatManager.CalculateBuoyancy` returns the water target as
`Vector3.new(0, TargetY, 0)`, and only its **Y** is meaningful. Feeding that
straight in tells the constraint to move the boat to world X=0, Z=0 as well —
with `ForceLimitMode.Magnitude` (the default) the horizontal error is serviced
out of the same `MaxForce` budget as the lift, so an idle boat far from the
origin is dragged toward it. Write the goal from the hull instead:

```lua
local height, orientation, depth = BoatManager.CalculateBuoyancy(...)
alignPosition.Position = Vector3.new(Main.Position.X, height.Y, Main.Position.Z)
```

or keep the packed vector and take the horizontal authority away entirely with
`ForceLimitMode.PerAxis` + `ForceRelativeTo.World` +
`MaxAxesForce = Vector3.new(0, lift, 0)`. Both are what
`ReplicatedStorage/FloatingObjectGeneration/WaveFloat.luau` does for every
generated prop, along with the per-frame refresh near players — the prop side
and the boat side are meant to move identically. Do not leave the old BodyMovers enabled alongside these
constraints, or the two controllers will fight.

The collision-group section is important: clamping the buoyancy goal alone does
not stop an island from physically pushing the boat upward. The boat must not
collide with island geometry if it is meant to stay on the water. If the boat
should still collide with docks or other objects, put those objects in a third
collision group rather than setting `Boat` to non-collidable globally.

## Current drive model (`ShipDrive`)

The snippets above are the legacy port. The live drive is in
`src/ReplicatedStorage/ShipHandling/ShipDrive.luau`, used by both
`Ship.Client` (the driver's machine) and `Ship.Handler` (the server, while
unmanned). It replaces the old instant `LinearVelocity` throttle with forces, so
the hull accelerates, coasts, brakes and sails by Newton's laws:

- **Throttle** (`VehicleSeat.Throttle`) spools toward its input at
  `ThrottleSpool` per second before it reaches the engine.
- **Engine**: constant thrust (`EngineAccel` ahead, `ReverseAccel` astern). Quadratic
  and linear drag set the top speed (about 29 studs/s ahead with the defaults).
- **Coasting and braking**: releasing the throttle lets the hull coast down. Throttle
  against the motion brakes harder (`BrakeAccel`), without overshooting zero.
- **Keel**: `LateralDamping` removes sideways speed, so the hull tracks its heading.
- **Sail** (hulls with a `Sail` child only — and **no playable hull has one**, verified
  2026-10-27: `WoodenShip` children are `Center, Truss, VehicleSeat, BoatWheel, Motor,
  Union, Union, Prim, Main, Handler, Client`; `MisoSoup` is `Handler, Union, Main,
  VehicleSeat, Parts, Client`; `Boathouse` has none; only the reference `ServerBoat`
  carries a `Sail` and it runs its own legacy handler). The sail branch is therefore dead
  code for the fleet: `Ship.Client` computes `sailAccel = 0` unless `Ship:FindFirstChild("Sail")`
  exists, so every playable hull is engine-only. Do **not** add or "restore" a sail — see
  the correction in `docs/agent-prompts/10-continue.md`. The wind path is kept because the
  reference boat is out of bounds.
- **Rudder**: `MaxTurnRate` scaled by forward speed over `TurnReferenceSpeed`, so a
  stopped hull does not spin. Reversing turns the bow the other way.
- **Unmanned**: the server applies drag only, so an abandoned hull coasts to a stop.
- **Draft**: the `Draft` attribute lowers the buoyancy goal. Measured values
  (2026-10-27): `WoodenShip` 5.5, `MisoSoup` **-7.3**, `Boathouse` 3.5. `Draft` is a
  clean 1:1 lever now — one stud of Draft is one stud deeper — because the goal is
  written in the mover's frame (see "Buoyancy frame" below). **The three values were
  never physical drafts**: they were compensating for a 15–17 stud frame error, so they
  need re-tuning by eye now that nothing is fighting them.

### Per-hull tuning (2026-10-27)

`ShipDrive.Defaults` is only the **fallback**. Every hull can override any `Tuning` field
with a NUMBER attribute of the same name on the ship model, and `ShipDrive.Resolve(ship)`
merges the two. Both sides resolve it — the `Client` clones against its own model and the
`Handler` sits inside it — and both re-resolve on `AttributeChanged`, so a value can be
edited on the live place and read back.

| Hull | `EngineAccel` | `ReverseAccel` | `BrakeAccel` | `LateralDamping` | `ThrottleSpool` | `MaxTurnRate` | `TurnReferenceSpeed` | top speed | turn radius |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `ServerBoat` (reference, Defaults) | 8 | 2 | 8 | 1.2 | 1.5 | 0.50 | 6 | 29.1 | 58.2 |
| `WoodenShip` (88 studs, 2663 mass) | 6.6 | 1.7 | 7.0 | 1.4 | 1.2 | 0.23 | 8 | 26.0 | 113.0 |
| `MisoSoup` (125 studs, 19565 mass) | 3.6 | 0.9 | 6.0 | 2.0 | 0.8 | 0.11 | 10 | 18.0 | 163.3 |
| `Boathouse` (45 studs, 2757 mass) | 2.4 | 0.7 | 5.0 | 1.2 | 1.0 | 0.24 | 6 | 13.9 | 57.8 |

How the numbers were derived, so they are not arbitrary:

- **Top speed** from the model's own drag balance, `EngineAccel = 0.08·v + 0.0067·v²`.
  `DragLinear`/`DragQuadratic` stay at Defaults on all three, so coasting feels like the
  reference and only the thrust differs.
- **Steering**: every hull's steady turn radius at its own top speed is ≈ **1.3 hull
  lengths**, which is the ratio the reference already has (58.2 on a 45-stud `Main`).
  `MaxTurnRate = TopSpeed / (1.3 · length)`.
- `ThrottleSpool`, `BrakeAccel`, `ReverseAccel`, `LateralDamping` scale with size.

Attributes are the tuning surface because Rojo cannot carry them for hand-made models;
`tools/studio-probes/ships/apply_ship_attributes.py` is the source of truth and `--check`
reads them back. `bash tools/measure/ship-tuning.sh` prints the table above plus
acceleration and coast curves, running the real `ShipDrive.luau` under plain Luau.

The sail value was set by a sweep, with a 14 studs/s breeze: beam reach about 17,
downwind about 6, close-hauled about 5.5 studs/s. It only matters if a hull ever gets a
`Sail` child.

## Ship guard: anti-climb and anti-sink (`ShipGuard`)

`src/ReplicatedStorage/ShipHandling/ShipGuard.luau` is shared by `Ship.Handler` and
`Ship.Client`. It acts on vertical motion only, so a ship still pushes unanchored
objects aside, and fixed objects still stop it.

- **Anti-climb.** While the hull touches a part outside the ship, a rising hull is held
  at zero rise. Ships do not ride up onto islands, floaters or anything else.
- **Anti-sink, contact.** When the hull is more than `ContactBand` (1 stud) below its
  buoyancy goal and touching something, it may not move down. A floater or overhang
  that presses on the hull cannot drive it under.
- **Anti-sink, floor.** Out of contact and more than `SinkMargin` (2.5 studs) below the
  goal, a soft floor lifts the hull back toward it, proportional and capped at `MaxRise`
  (20 studs/s).
- **Servo reserve.** Below the band, the buoyancy servo's force limit rises with the gap
  (`ReserveGain`, capped at `ReserveMax` times the hull's weight). This is what holds
  against a sustained load. A velocity clamp alone cannot: a steady force still moves the
  hull every physics step, so zeroing velocity each frame does not stop a sink.

The guard's reference is not the lift goal. The goal (`targetY - Draft`) includes a drag
term on the hull's own centre of mass, so it falls as the hull sinks and the gap never
grows. The reference is the sea surface under the hull (mean of the four corner heights,
`seaSurfaceAt` in `Ship.Handler`) plus `SinkRestOffset`. That attribute defaults to
`baseHeight - Draft + (moverY - centreY)`, i.e. mover space, because `ResolveVertical`
tests the mover. `WoodenShip` sets `SinkRestOffset = -2`; `MisoSoup` 2.4; `Boathouse` has
none. Set it per ship, not in the guard.

Historical measurements (server probes, unmanned, steady downward push as a multiple of
the hull's weight; height is the hull's Main Y minus the sea surface). These were taken
**before** the fixes below, on hulls whose lift was fighting them, and the non-existent
`Boat` rows are kept only because they describe the reference's behaviour:
- (pre-fix) Boat, 6x: settled -2.15, lowest -3.16, recovered -2.42. With the floor
  switched off (control), the Boat sank about 550 studs and was destroyed by the world's
  fall-destroy.
- (pre-fix) WoodenShip, 6x: settled -0.93, lowest -6.27, still bobbing about ±4. Not solved.
- (pre-fix) WoodenShip, 6x with a block touching the `Union`: 3 of 24 frames in contact,
  lowest -5.91 from settled -1.95.

## Buoyancy is a force, not a servo (2026-10-27)

The "next step" that used to be written here — *an explicit upward `VectorForce` spring
with damping* — **is built and is what ships now use.** Two problems made it necessary:

1. **The airborne gate tested the hull centre.** `WaveFloat.Solve` returns `nil` when
   `surfaceY - waterlineY <= AIRBORNE_DEPTH (-0.5)`. `Ship.Client`/`Handler` passed
   `Main.Center`, while the reference `BoatManager` passes `Bottom.Y`. A hull at rest has
   its centre above the water and its bottom under it, so the solver returned nil every
   few frames, the servo switched off, the hull free-fell at up to -27 studs/s, crossed
   the threshold and was thrown back at +25. Instrumented: **7 servo `Enabled` toggles in
   2.2 s** with the hull bottom 1.7 studs underwater. This was the ship "bouncing".
2. **`AlignPosition` cannot hold a heavy hull against gravity.** Isolated test: with the
   goal 4 studs *below* the attachment, the hull accelerated **upward** at ~5× gravity and
   rose 5.2 studs.

Both are fixed. `waterlineY` is now `Main.Center.WorldPosition.Y - baseHeight`, and the
vertical drive is an explicit spring-damper force in `Ship.Handler` and `Ship.Client`:

```lua
local BUOY_KP, BUOY_KD, BUOY_FORCE_CAP = 12, 32, 3
local SUBMERGE_RAMP = 1.0
local errY = goal - here.Y                       -- centre-space error
local submerge = math.clamp((surface - bottomY) / SUBMERGE_RAMP, 0, 1)
local lift = submerge * mass * (workspace.Gravity + BUOY_KP * errY - BUOY_KD * vNow.Y)
buoyancyForce.Force = Vector3.new(0, math.clamp(lift, 0, mass * workspace.Gravity * BUOY_FORCE_CAP), 0)
```

Three things about that shape are load-bearing, each learned from a measured bounce:

* **`submerge`, not a gate.** `WaveFloat.Solve` returns nil when it thinks the hull is
  airborne, and dropping the lift on those frames made hulls fall and get caught at 2 Hz
  (39% of frames at zero lift on `MisoSoup`). Submergence fades the lift continuously, so a
  hull thrown into the air gets none and a floating hull gets all of it, with nothing to
  chatter. The last good target is kept, so no frame is left without one.
* **`KD` = 32, not 8.** The ramp is itself a spring of `g/SUBMERGE_RAMP` = 196 s⁻², far
  stiffer than `KP`; damping sized for `KP` alone (ζ ≈ 0.24) leaves the hull ringing at ~3 Hz
  around an otherwise correct depth. Critical is ~29.
* **The occupant is not an obstacle.** `touchingOutside()` must ignore parts belonging to the
  seated player, or anti-climb holds every rising frame at zero while the buoyancy lifts —
  and the server must not run its own anti-climb while a player is aboard, because two peers
  writing `AssemblyLinearVelocity` on one assembly is a fight, not a share.

It can only push **up** (clamped at 0) — buoyancy cannot pull a hull under — and the
damping is explicit, so it cannot overshoot into a limit cycle. `AlignPosition` is left in
place, disabled, so nothing else that looks for it breaks.

Measured on `WoodenShip`, unmanned, open water at a fixed XZ, 6 s window after settling:

| | before | after |
| --- | --- | --- |
| vertical-velocity reversals | 24 (≈2 Hz) | **0** |
| peak \|vy\| | 31.2 studs/s | **2.0** |
| offset span | 5.85 studs | 8.07 studs (slow settling, velocity never changes sign) |

Settled offsets after the fixes (`Main.Center` minus the analytic surface, last 5 s):
`WoodenShip` +0.88, `MisoSoup` +0.48, `Boathouse` +0.73. Before: `WoodenShip` -4.00, deck
2.3 studs under water.

Reference note: `ServerBoat` rides **12.4 studs above** the water (hull bottom 10.7 clear).
It is out of bounds and was not changed, but it is the reason the other hulls' `Draft`
values were negative or large — they were pulling down toward a reference that hovers.

`BUOY_KP` / `BUOY_KD` at the top of `Ship/Handler.server.luau` and `Ship/Client.client.luau`
are the two knobs if a hull feels sluggish getting onto a wave. Critical damping is
≈ 2√KP = 6.9, so 8 is slightly over-damped.

### Client (driver's machine)

`Ship.Client` uses the same surface reference as the Handler (`seaSurfaceAt` plus
`SinkRestOffset`, default `baseHeight - Draft + (moverY - centreY)`). It was updated after
the Handler, so the goal-based reference is gone from both.

`WoodenShip.Client` is **no longer Disabled or stale**: it was brought onto the current
script on 2026-10-26 (commit `a4ef9a0`) and all three hulls carry byte-identical copies of
the current `Handler` and `Client` (verified by hash, `tools/studio-probes/bridge/parity_hash.py`,
39/39 pairs matching).

**Not verified:** every measurement in this document is the server's *unmanned* path. The
occupied path (`Ship.Client`, the driver's machine) got identical changes but has not been
sampled — boarding a hull is the check.
