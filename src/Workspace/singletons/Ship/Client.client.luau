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
-- This hull's own handling (ShipDrive.Resolve reads the model's attributes), re-read
-- if the tuning attributes are changed while the ship is in use.
local tuning = ShipDrive.Resolve(Ship)
Ship.AttributeChanged:Connect(function()
	tuning = ShipDrive.Resolve(Ship)
end)

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

-- Vertical buoyancy is a spring-damper FORCE, not a position servo. The AlignPosition
-- could not do this job: its goal is a world position, so on a heavy rigid body it either
-- yanked or fought gravity, and `WaveFloat.Solve` returns nil whenever the hull CENTRE is
-- above the water -- which is exactly where a ship at rest sits -- so the constraint
-- toggled on and off every few frames. Measured on WoodenShip: 7 Enabled toggles in 2.2 s,
-- ~2 Hz, 31 studs/s peak vertical speed, 5.8 studs of offset span. That was the bounce.
--
-- This force can only ever push UP (clamped at zero), which is what buoyancy is, and it is
-- explicitly damped, so it cannot overshoot into a limit cycle.
local BUOY_KP = 12 -- 1/s^2, how hard to chase the waterline
-- Damping has to match the STIFFEST spring in the loop, not just KP. The submergence ramp
-- below is itself a spring: it changes the lift by one hull weight per SUBMERGE_RAMP studs,
-- which is g/SUBMERGE_RAMP = 196 s^-2 -- sixteen times stiffer than KP. The two add, so the
-- loop's stiffness is about 196 + 12 = 208 s^-2, natural frequency ~14.4 rad/s, and
-- critical damping needs KD ~= 2*14.4 = 29. At the old KD = 8 the damping ratio was 0.24:
-- measured on MisoSoup with a player aboard, the hull rang at ~3 Hz, 32 vertical reversals
-- in 6 s, peak 12.9 studs/s, around an otherwise correct depth. 32 is very slightly
-- over-damped (zeta ~1.1) so it settles without overshoot.
local BUOY_KD = 32 -- 1/s, damping
local BUOY_FORCE_CAP = 3 -- cap on the lift, in multiples of the hull's weight
-- How far the hull's bottom must be under the surface for the lift to be at full
-- strength. Above this the lift fades out over the same distance, reaching zero as the
-- bottom clears the water. Buoyancy is proportional to displaced water, so this is a
-- RAMP, not a switch -- see the note where it is computed.
local SUBMERGE_RAMP = 1.0
-- The last non-nil Solve target. Solve returns nil when its own airborne gate trips, and
-- dropping the lift for those frames is what made hulls bounce.
local lastTargetY: number? = nil
local state = { lastSurface = nil, lastSurfaceAt = nil, surfaceVy = 0 }

-- Sea surface under the hull: the mean of the four corner heights, as WaveFloat.Solve
-- computes its surface. Nil only if every corner lookup failed.
local function seaSurfaceAt(zone, now: number): number?
	local sum, count = 0, 0
	for _, point in buoyancyPoints do
		local h = WaveFloat.HeightAt(point.WorldPosition, zone, nil, "ANALYTIC", now)
		if h ~= nil then
			sum += h
			count += 1
		end
	end
	if count == 0 then
		return nil
	end
	return sum / count
end
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

local buoyancyForce = Instance.new("VectorForce")
buoyancyForce.Name = "ShipBuoyancyForce"
buoyancyForce.Attachment0 = moverAttachment
buoyancyForce.RelativeTo = Enum.ActuatorRelativeTo.World
buoyancyForce.ApplyAtCenterOfMass = true
buoyancyForce.Force = Vector3.zero
buoyancyForce.Parent = VehicleSeat

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
-- A player sitting in the seat is not an obstacle. Their character's parts are welded to
-- the hull but they are NOT descendants of the ship model, so the old test reported
-- "touching something outside" for as long as anyone was aboard -- and anti-climb then
-- pinned every rising frame to zero while the buoyancy lift pushed up. That is the bounce
-- you see from the driver's seat: measured on MisoSoup with a player aboard, 30 vertical
-- reversals in 6 s at 5/s, peak 16.4 studs/s, while the same hull with nobody in it was
-- flat. Keep treating real world geometry as contact.
local function isOccupantPart(part): boolean
	local occupant = VehicleSeat.Occupant
	local character = occupant and occupant.Parent
	if not character then
		return false
	end
	return part:IsDescendantOf(character)
end

local function touchingOutside(): boolean
	for _, instance in ipairs(shipModel:GetDescendants()) do
		if instance:IsA("BasePart") and instance.CanCollide then
			for _, other in ipairs(instance:GetTouchingParts()) do
				if not other:IsDescendantOf(shipModel) and not isOccupantPart(other) then
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
	local now = workspace:GetServerTimeNow()
	-- `waterlineY` is the depth reference the airborne gate tests, and it must be the
	-- hull's BOTTOM, exactly as BoatManager passes `Bottom.Y` for the reference
	-- ServerBoat. Passing the hull centre made the gate fire while the ship was
	-- floating: on WoodenShip the centre rides ~4 studs above the water and the bottom
	-- ~1.7 under it, so `depth <= AIRBORNE_DEPTH` was true every few frames, the solver
	-- returned nil, the servo switched off, the hull free-fell at up to -27 studs/s,
	-- crossed the threshold, was caught and thrown back up at +25 (measured: 7 servo
	-- Enabled toggles in 2.2 s, ~2 Hz). That was the ship "bouncing".
	local bottomY = Main.Center.WorldPosition.Y - baseHeight
	local targetY, orientation, depth = WaveFloat.Solve(
		buoyancyPoints,
		Main.CenterOfMass.Y,
		bottomY,
		boatLength,
		boatWidth,
		baseHeight,
		currentZoneInfo,
		"ANALYTIC",
		nil,
		now
	)

	-- `nil` means the hull is airborne: stop driving it and let gravity bring
	-- it back down. Orientation is still commanded so it lands in the right pose.
	-- Solve's own gate returns nil as soon as the hull's bottom clears the surface. That
	-- is a HARD switch, and it was the whole bounce: on MisoSoup the lift vanished for
	-- 39% of frames, the hull fell, re-entered and was caught again -- 2 Hz, peak
	-- 20.9 studs/s. WoodenShip escaped it only because its Draft keeps its bottom under
	-- the water. So: keep the last good target, and let submergence below fade the lift
	-- out continuously instead of cutting it.
	if targetY ~= nil then
		lastTargetY = targetY
	end
	local aimY = targetY or lastTargetY
	if aimY ~= nil then
		-- Goal X/Z is the mover's own column, so the horizontal error is zero
		-- and the servo only corrects height (see the PerAxis note above).
		local here = moverAttachment.WorldPosition
		alignPosition.Enabled = false -- replaced by the PD force below
		-- Draft (WoodenShip's attribute, 0 on Boat) lowers the goal so the hull sits
		-- under the surface like the Boat does.
		--
		-- Draft is measured against the HULL CENTRE, which is what Solve returns, but
		-- the servo drives the attachment on the VehicleSeat. On a hull whose helm is
		-- well above its centre (WoodenShip: 16 studs) writing the centre height into
		-- the servo commands that much extra sink; the servo saturates, the hull lags
		-- the waves and the water rides over the deck. Put the goal in the mover's own
		-- frame instead: the hull centre then settles exactly on targetY - Draft.
		local draft = Ship:GetAttribute("Draft") or 0
		local goal = here.Y + ((aimY - draft) - Main.Center.WorldPosition.Y)
		alignPosition.Position = Vector3.new(here.X, goal, here.Z)
		-- Servo authority rises while the hull is below its band, so it can hold a load.
		-- Guard reference: sea surface plus SinkRestOffset (default baseHeight - Draft).
		-- The goal above is not used for this, because its drag term falls with the hull.
		local surface = seaSurfaceAt(currentZoneInfo, now)
		local reference = goal
		if surface ~= nil then
			reference = surface
				+ (Ship:GetAttribute("SinkRestOffset")
					or (baseHeight - draft + (here.Y - Main.Center.WorldPosition.Y)))
		end

		-- Submergence, 0..1: full lift once the bottom is SUBMERGE_RAMP under the surface,
		-- none once it has cleared it. Continuous, so it cannot chatter the way the old
		-- nil/no-nil switch did, and a hull thrown into the air correctly gets no lift.
		local submerge = 1
		if surface ~= nil then
			submerge = math.clamp((surface - bottomY) / SUBMERGE_RAMP, 0, 1)
		end
		local reserve = ShipGuard.ServoReserve(ShipGuard.Gap(here.Y, reference))
		-- How fast the water itself is moving here, for the relative damping below. A finite
		-- difference on the surface we already sampled, clamped so a teleport cannot inject a
		-- huge term, and low-passed so the force does not chase sampling noise.
		local surfaceVy = 0
		if surface ~= nil then
			if state.lastSurface ~= nil and state.lastSurfaceAt ~= nil then
				local dt = now - state.lastSurfaceAt
				if dt > 1e-3 and dt < 0.5 then
					local raw = math.clamp((surface - state.lastSurface) / dt, -30, 30)
					surfaceVy = state.surfaceVy + (raw - state.surfaceVy) * 0.35
				end
			end
			state.surfaceVy = surfaceVy
			state.lastSurface = surface
			state.lastSurfaceAt = now
		end
		-- Spring-damper lift on the vertical axis (see BUOY_KP above). `goal` is the mover
		-- goal in world space, so `goal - here.Y` is the centre-space error.
		local errY = goal - here.Y
		local vNow = Main.AssemblyLinearVelocity
		local mass = Main.AssemblyMass
		-- Damp against the WATER, not against the world. `KD * vy` resists a hull that is
		-- merely riding a wave, which is the motion we want it to have: measured on the
		-- occupied hull at speed, it followed only 29% of the swell (correlation +0.28) and
		-- the water ran up to 3 studs over the deck. Damping the RELATIVE velocity leaves the
		-- error dynamics identical (same characteristic equation, so the rest behaviour the
		-- bounce fix bought is untouched) and removes the false resistance to wave-following.
		local lift = submerge * mass * (workspace.Gravity + BUOY_KP * errY - BUOY_KD * (vNow.Y - surfaceVy))
		buoyancyForce.Force = Vector3.new(0, math.clamp(lift, 0, mass * workspace.Gravity * BUOY_FORCE_CAP), 0)
		-- Anti-sink: a hull well below its reference is lifted, and contact holds it.
		local v = Main.AssemblyLinearVelocity
		local vy = ShipGuard.ResolveVertical(v.Y, here.Y, reference, touchingOutside)
		if vy ~= v.Y then
			Main.AssemblyLinearVelocity = Vector3.new(v.X, vy, v.Z)
		end
	else
		alignPosition.Enabled = false
		buoyancyForce.Force = Vector3.zero
	end

	alignOrientation.CFrame = CFrame.fromEulerAnglesXYZ(0, currentRotation, 0) * orientation

	if zoneAccumulated >= 3 then
		zoneAccumulated = 0
		updateZoneMultipliers()
	end
end)

ZoneManager.ZoneUpdated:Connect(updateZoneMultipliers)
