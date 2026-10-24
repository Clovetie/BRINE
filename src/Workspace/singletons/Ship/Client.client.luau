--!native
--!strict
--!optimize 2

local shipReference = script:WaitForChild("Ship") :: ObjectValue
local Ship = shipReference.Value :: Model
local RunService = game:GetService("RunService")
local ZoneManager = require(game.ReplicatedStorage.Gerstner.Serial.ZoneManager)
-- The same buoyancy solver the floating props use (ROADMAP 2.4): one physics
-- model for the boat and for everything else on the water.
local WaveFloat = require(game.ReplicatedStorage.FloatingObjectGeneration.WaveFloat)

local Main = Ship:WaitForChild("Main") :: BasePart
local VehicleSeat = Ship:WaitForChild("VehicleSeat") :: VehicleSeat

workspace.CurrentCamera.CameraType = Enum.CameraType.Track

local buoyancyPoints = {
	Main:WaitForChild("TopLeft") :: Attachment,
	Main:WaitForChild("TopRight") :: Attachment,
	Main:WaitForChild("BottomLeft") :: Attachment,
	Main:WaitForChild("BottomRight") :: Attachment,
}

local boatWidth = Main.Size.X
local boatLength = Main.Size.Z
local baseHeight = Main.Size.Y / 2
-- Force limits follow the hull's mass at runtime (ROADMAP 2.2). They are
-- derived in RefreshForceLimits, not read once at startup.
local maxForce = 0
local throttleForce = 0
local lastMass = -1

local moverAttachment = Instance.new("Attachment")
moverAttachment.Name = "ShipMoverAttachment"
moverAttachment.Parent = VehicleSeat

-- Buoyancy is vertical only (ROADMAP 2.5 / BOAT_HANDLER.md). In OneAttachment
-- mode `Position` is a WORLD goal, and with the default Magnitude limit any
-- horizontal error in it is paid out of the same MaxForce that lifts the hull.
-- PerAxis + World with zero X/Z authority means the servo can only push along
-- Y; horizontal motion belongs to the throttle LinearVelocity alone.
local alignPosition = Instance.new("AlignPosition")
alignPosition.Name = "ShipBuoyancy"
alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
alignPosition.Attachment0 = moverAttachment
alignPosition.ApplyAtCenterOfMass = true
alignPosition.ForceLimitMode = Enum.ForceLimitMode.PerAxis
alignPosition.ForceRelativeTo = Enum.ActuatorRelativeTo.World
alignPosition.MaxVelocity = 80
alignPosition.Responsiveness = 12
alignPosition.RigidityEnabled = false
-- Seed the goal at the mover's own position and stay disabled until the first
-- solve. The default goal is the world origin, which would yank the hull
-- toward (0, 0, 0) for a frame.
alignPosition.Position = moverAttachment.WorldPosition
alignPosition.Enabled = false
alignPosition.Parent = VehicleSeat

local alignOrientation = Instance.new("AlignOrientation")
alignOrientation.Name = "ShipWaveOrientation"
alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
alignOrientation.Attachment0 = moverAttachment
alignOrientation.MaxAngularVelocity = 8
alignOrientation.Responsiveness = 12
alignOrientation.RigidityEnabled = false
alignOrientation.Parent = VehicleSeat

-- The throttle is horizontal only. With Vector mode and zero velocity on every
-- axis, a Magnitude-limited throttle also cancelled Y: it held the hull at its
-- current height and buoyancy could not lift or lower it. PerAxis with zero Y
-- authority leaves vertical motion to the buoyancy servo alone (ROADMAP 2.5).
local linearVelocity = Instance.new("LinearVelocity")
linearVelocity.Name = "ShipThrottle"
linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
linearVelocity.Attachment0 = moverAttachment
linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
linearVelocity.ForceLimitsEnabled = true
linearVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
linearVelocity.Parent = VehicleSeat

-- Recomputes every force limit from the current AssemblyMass. Runs at once and then each
-- frame, but only writes when the mass has changed (the hull mass changes when cargo or
-- a rider joins the assembly).
local function RefreshForceLimits()
	local mass = Main.AssemblyMass
	if mass == lastMass then
		return
	end
	lastMass = mass
	maxForce = mass * workspace.Gravity * 4
	throttleForce = mass * workspace.Gravity * 3
	alignPosition.MaxAxesForce = Vector3.new(0, maxForce, 0)
	alignOrientation.MaxTorque = mass * 5000
	linearVelocity.MaxAxesForce = Vector3.new(throttleForce, 0, throttleForce)
end
RefreshForceLimits()

-- This Client is destroyed when the player leaves. Remove the constraints it made
-- here, so they cannot keep pushing the hull on this machine after the server
-- takes over the unmanned ship (ROADMAP 2.6).
script.Destroying:Connect(function()
	moverAttachment:Destroy()
	alignPosition:Destroy()
	alignOrientation:Destroy()
	linearVelocity:Destroy()
end)

local currentZoneInfo = {
	SpeedMultiplier = 1,
	PhaseMultiplier = 1,
	AmplitudeMultiplier = 1,
	CURRENT_ZONE = nil,
}

local function updateZoneMultipliers()
	currentZoneInfo.CURRENT_ZONE = ZoneManager:GetZoneParameters(Main.Position)
end

local zoneAccumulated = 0
local currentRotation = 0
updateZoneMultipliers()

RunService.PostSimulation:Connect(function(dt)
	RefreshForceLimits()
	zoneAccumulated += dt

	local currentZone = currentZoneInfo.CURRENT_ZONE
	if currentZone then
		if currentZone.Type ~= "Whirlpool" and currentZone.Link then
			local position = currentZone.Link.Position
			currentZoneInfo.PhaseMultiplier, currentZoneInfo.SpeedMultiplier, currentZoneInfo.AmplitudeMultiplier =
				ZoneManager:GetZoneMultipliers(Main.Position, position, currentZone)
		elseif currentZone.Type ~= "Whirlpool" and currentZone.Island then
			local islandPosition = currentZone.Island.Center.Position
			local radius = currentZone.Radius / 2
			currentZoneInfo.PhaseMultiplier, currentZoneInfo.SpeedMultiplier, currentZoneInfo.AmplitudeMultiplier =
				ZoneManager:GetIslandMultipliers(Main.Position, islandPosition, radius)
		end
	end

	if VehicleSeat.Steer == 1 then
		currentRotation -= math.rad(0.5)
	elseif VehicleSeat.Steer == -1 then
		currentRotation += math.rad(0.5)
	end

	-- Drive along the hull's heading on the horizontal plane only: a pitched
	-- LookVector would otherwise ask for vertical speed the throttle may not give.
	local look = VehicleSeat.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if VehicleSeat.Throttle == 1 and flat.Magnitude > 1e-3 then
		linearVelocity.VectorVelocity = flat.Unit * 30
	else
		linearVelocity.VectorVelocity = Vector3.zero
	end

	-- Analytic surface (the Gerstner sum the ocean mesh is displaced with), so
	-- the ship floats without needing HeightLookup.ClientInit on the client.
	local targetY, orientation, depth = WaveFloat.Solve(
		buoyancyPoints,
		Main.CenterOfMass.Y,
		Main.Center.WorldPosition.Y,
		boatLength,
		boatWidth,
		baseHeight,
		currentZoneInfo,
		"ANALYTIC",
		nil,
		workspace:GetServerTimeNow()
	)

	-- `nil` means the hull is airborne: stop driving it and let gravity bring
	-- it back down. Orientation is still commanded so it lands in the right pose.
	if targetY ~= nil then
		-- Goal X/Z is the mover's own column, so the horizontal error is zero
		-- and the servo only corrects height (see the PerAxis note above).
		local here = moverAttachment.WorldPosition
		alignPosition.Enabled = true
		alignPosition.MaxAxesForce = Vector3.new(0, maxForce * (1 + (depth / 10)), 0)
		alignPosition.Position = Vector3.new(here.X, targetY, here.Z)
	else
		alignPosition.Enabled = false
	end

	alignOrientation.CFrame = CFrame.fromEulerAnglesXYZ(0, currentRotation, 0) * orientation

	if zoneAccumulated >= 3 then
		zoneAccumulated = 0
		updateZoneMultipliers()
	end
end)

ZoneManager.ZoneUpdated:Connect(updateZoneMultipliers)
