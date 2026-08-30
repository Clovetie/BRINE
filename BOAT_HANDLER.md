# Boat handler update

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
one-attachment mode. Do not leave the old BodyMovers enabled alongside these
constraints, or the two controllers will fight.

The collision-group section is important: clamping the buoyancy goal alone does
not stop an island from physically pushing the boat upward. The boat must not
collide with island geometry if it is meant to stay on the water. If the boat
should still collide with docks or other objects, put those objects in a third
collision group rather than setting `Boat` to non-collidable globally.
