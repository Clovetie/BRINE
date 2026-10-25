# Boat handler update

> **Status: implemented on `main`.** The buoyancy and mover setup described below live in
> `src/Workspace/singletons/Ship/Client.client.luau` (the ship client now solves its
> surface with `ReplicatedStorage.FloatingObjectGeneration.WaveFloat`, and `BoatManager`
> is a compatibility adapter). The snippets below are kept as the reference for
> porting a *legacy* BodyMover boat; the repo copy is the source of truth.

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
- **Sail** (hulls with a `Sail` child only, currently `Boat`): thrust from the
  apparent wind (`workspace.GlobalWind` direction at `WindSpeed`, minus the hull's
  own velocity). Nothing in irons, best on a beam reach, a little less dead downwind.
  Small leeway, damped by the keel. The sail mesh does not trim visually yet.
- **Rudder**: `MaxTurnRate` scaled by forward speed over `TurnReferenceSpeed`, so a
  stopped hull does not spin. Reversing turns the bow the other way.
- **Unmanned**: the server applies drag only, so an abandoned hull coasts to a stop.
- **Draft**: the `Draft` attribute lowers the buoyancy goal (0 on `Boat`, 5.5 on
  `WoodenShip`).

Tuning lives in `ShipDrive.Defaults`. The sail value was set by a sweep, with a
14 studs/s breeze: beam reach about 17, downwind about 6, close-hauled about 5.5
studs/s. `WoodenShip` has no `Sail` child and so is engine-only.

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

The guard's reference is not the servo goal. The goal (`targetY - Draft`) includes a drag
term on the hull's own centre of mass, so it falls as the hull sinks and the gap never
grows. The reference is the sea surface under the hull (mean of the four corner heights,
`seaSurfaceAt` in `Ship.Handler`) plus `SinkRestOffset`. That attribute defaults to
`baseHeight - Draft`. WoodenShip sets `SinkRestOffset = -2` (measured: its hull rests about
2 studs below the surface). Set it per ship, not in the guard.

Measurements (server probes, unmanned, steady downward push as a multiple of the hull's
weight). Settled height is the hull's Main Y minus the sea surface.
- Boat, 6x: settled -2.15, lowest -3.16, recovered -2.42. Earlier, with the goal as the
  reference: lowest -5.06. With the floor switched off (control), the Boat sank about 550
  studs and was destroyed by the world's fall-destroy.
- WoodenShip, 2x: settled -2.89, lowest -3.26.
- WoodenShip, 6x: settled -0.93, lowest -6.27 (about 5 studs), still bobbing about +/-4.
  Not solved. Responsiveness 4 during the push did not help (lowest -7.37).
- WoodenShip, 6x with a block touching the `Union` (`probes/sink_contact2.lua`): 3 of 24
  frames in contact, lowest -5.91 from settled -1.95.

Open: a steady 6x load on WoodenShip still sinks about 5 studs. The next step is an
explicit upward `VectorForce` spring with damping, which would not depend on the velocity
clamp and the servo fighting each physics step. Not built yet.
