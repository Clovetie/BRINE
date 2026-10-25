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
-- Engine, drag, braking, keel, sail and rudder model (shared with Ship.Handler).
local ShipDrive = require(game.ReplicatedStorage.ShipHandling.ShipDrive)
-- Anti-climb and anti-sink (ROADMAP ship guard), shared with Ship.Handler.
local ShipGuard = require(game.ReplicatedStorage.ShipHandling.ShipGuard)
local tuning = ShipDrive.Defaults

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
-- Buoyancy force limit follows the hull's mass at runtime (ROADMAP 2.2). It is
-- derived in RefreshForceLimits, not read once at startup.
local maxForce = 0
local lastMass = -1
-- Spooled throttle: the engine answers the seat's input over time, not instantly.
local command = 0

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

-- Drive force (ROADMAP 2.5 / ship handling). A VectorForce the client writes each
-- frame from ShipDrive, so the hull accelerates, coasts, brakes and sails by Newton's
-- laws. It is horizontal only; vertical motion belongs to the buoyancy servo alone.
local drive = Instance.new("VectorForce")
drive.Name = "ShipDrive"
drive.Attachment0 = moverAttachment
drive.RelativeTo = Enum.ActuatorRelativeTo.World
drive.ApplyAtCenterOfMass = true
drive.Force = Vector3.zero
drive.Parent = VehicleSeat

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
	alignPosition.MaxAxesForce = Vector3.new(0, maxForce, 0)
	alignOrientation.MaxTorque = mass * 5000
end
RefreshForceLimits()

-- This Client is destroyed when the player leaves. Remove the constraints it made
-- here, so they cannot keep pushing the hull on this machine after the server
-- takes over the unmanned ship (ROADMAP 2.6).
script.Destroying:Connect(function()
	moverAttachment:Destroy()
	alignPosition:Destroy()
	alignOrientation:Destroy()
	drive:Destroy()
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

-- Anti-climb and anti-sink. The driver's machine owns the hull while someone is
-- aboard, so the guard runs here as well as on the Handler. Contact with anything
-- outside the ship holds the hull's vertical motion, and the floor lifts a hull that
-- sinks well below its waterline goal (set in the solve below).
local shipModel = VehicleSeat.Parent :: Instance
local function touchingOutside(): boolean
	for _, instance in ipairs(shipModel:GetDescendants()) do
		if instance:IsA("BasePart") and instance.CanCollide then
			for _, other in ipairs(instance:GetTouchingParts()) do
				if not other:IsDescendantOf(shipModel) then
					return true
				end
			end
		end
	end
	return false
end

RunService.PostSimulation:Connect(function()
	local v = Main.AssemblyLinearVelocity
	local vy = ShipGuard.ResolveVertical(v.Y, Main.Position.Y, nil, touchingOutside)
	if vy ~= v.Y then
		Main.AssemblyLinearVelocity = Vector3.new(v.X, vy, v.Z)
	end
end)

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

	-- Heading: the rudder turns the hull only while it is moving, and turns it
	-- faster the faster it goes (ShipDrive.YawRate). Positive Steer turns the bow
	-- the same way as before.
	local look = VehicleSeat.CFrame.LookVector
	local forward = Vector3.new(look.X, 0, look.Z)
	local velocity = Main.AssemblyLinearVelocity
	if forward.Magnitude > 1e-3 then
		forward = forward.Unit
		local right = forward:Cross(Vector3.yAxis)
		local forwardSpeed = Vector3.new(velocity.X, 0, velocity.Z):Dot(forward)
		currentRotation -= ShipDrive.YawRate(forwardSpeed, VehicleSeat.Steer, tuning) * dt

		-- Throttle spools toward the seat input. Wind comes from the same direction
		-- as the waves (workspace.GlobalWind) at the tuning's breeze speed.
		command = ShipDrive.Spool(command, VehicleSeat.Throttle, dt, tuning)
		local wind = Vector3.new(workspace.GlobalWind.X, 0, workspace.GlobalWind.Z)
		local trueWind = if wind.Magnitude > 1e-3 then wind.Unit * tuning.WindSpeed else Vector3.zero
		-- A hull with a Sail model is sail-driven. Hulls without one get no sail term.
		local sailAccel = if Ship:FindFirstChild("Sail") then (Ship:GetAttribute("SailAccel") or tuning.SailAccel) else 0
		local accel = ShipDrive.Acceleration(velocity, forward, right, command, dt, trueWind, sailAccel, tuning)
		drive.Force = accel * Main.AssemblyMass
	else
		command = 0
		drive.Force = Vector3.zero
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
		-- Draft (WoodenShip's attribute, 0 on Boat) lowers the goal so the hull sits
		-- under the surface like the Boat does.
		local goal = targetY - (Ship:GetAttribute("Draft") or 0)
		alignPosition.Position = Vector3.new(here.X, goal, here.Z)
		-- Servo authority rises while the hull is below its band, so it can hold a load.
		local reserve = ShipGuard.ServoReserve(ShipGuard.Gap(here.Y, goal))
		alignPosition.MaxAxesForce = Vector3.new(0, maxForce * (1 + (depth / 10) + reserve), 0)
		-- Anti-sink: a hull well below its goal is lifted, and contact holds it.
		local v = Main.AssemblyLinearVelocity
		local vy = ShipGuard.ResolveVertical(v.Y, here.Y, goal, touchingOutside)
		if vy ~= v.Y then
			Main.AssemblyLinearVelocity = Vector3.new(v.X, vy, v.Z)
		end
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
