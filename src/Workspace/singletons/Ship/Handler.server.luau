--!native
--!strict
--!optimize 2

-- Ship singleton (server side). The model must contain Main, VehicleSeat, and Client.
local Ship = script.Parent :: Model
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local WaveFloat = require(ReplicatedStorage.FloatingObjectGeneration.WaveFloat)
local ShipDrive = require(ReplicatedStorage.ShipHandling.ShipDrive)
local ShipGuard = require(ReplicatedStorage.ShipHandling.ShipGuard)
local ZoneManager = require(ReplicatedStorage.Gerstner.Serial.ZoneManager)

local VehicleSeat = Ship:WaitForChild("VehicleSeat") :: VehicleSeat
local Main = Ship:WaitForChild("Main") :: BasePart
-- Server authority while the ship is unmanned. This is not cosmetic: whoever COMPUTES
-- the buoyancy must also OWN the simulation. A hull that is client-owned while the
-- server computes the lift is driven by a force derived from a stale replicated
-- velocity, arriving a network round-trip later -- a delayed feedback loop, which is
-- exactly the shape that turns a damped spring into an oscillator. Studio Play has no
-- latency, so nothing measured there can show it; a live server can.
--
-- Guarded because SetNetworkOwner throws on an assembly that cannot be reassigned (for
-- example one welded to an anchored part). Unguarded, a single throw here kills the
-- whole handler and the hull gets no buoyancy at all.
pcall(function()
	VehicleSeat:SetNetworkOwner(nil)
end)

-- This hull's own handling (ShipDrive.Resolve reads the model's attributes), re-read if
-- the tuning attributes are changed while the ship is idle.
local tuning = ShipDrive.Resolve(Ship)
Ship.AttributeChanged:Connect(function()
	tuning = ShipDrive.Resolve(Ship)
end)

local function registerCollisionGroup(name: string)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
end

registerCollisionGroup("Ship")
registerCollisionGroup("ShipIsland")
-- Fixed islands block the hull. The anti-climb guard below stops
-- the hull riding up them; the pair used to be non-collidable, which let ships
-- pass through islands instead.
PhysicsService:CollisionGroupSetCollidable("Ship", "ShipIsland", true)

local function markIsland(instance: Instance)
	if instance:IsA("BasePart") then
		instance.CollisionGroup = "ShipIsland"
	end
end

local map = workspace:FindFirstChild("Map")
if map then
	for _, instance in ipairs(map:GetDescendants()) do
		markIsland(instance)
	end
	map.DescendantAdded:Connect(markIsland)
end

-- Rising islands are parented to workspace._RisingIslands before they reach
-- Map (ROADMAP 4.4). Tag them from the moment they appear, so the ship cannot
-- collide with an island mid-rise.
local RISING_ISLANDS_FOLDER_NAME = "_RisingIslands"
local function watchRisingFolder(folder: Instance)
	for _, instance in ipairs(folder:GetDescendants()) do
		markIsland(instance)
	end
	folder.DescendantAdded:Connect(markIsland)
end

local risingFolder = workspace:FindFirstChild(RISING_ISLANDS_FOLDER_NAME)
if risingFolder then
	watchRisingFolder(risingFolder)
end
workspace.ChildAdded:Connect(function(child)
	if child.Name == RISING_ISLANDS_FOLDER_NAME then
		watchRisingFolder(child)
	end
end)

for _, instance in ipairs(Ship:GetDescendants()) do
	if instance:IsA("BasePart") then
		instance.CollisionGroup = "Ship"
	end
end

-- Unmanned buoyancy (ROADMAP 2.6). While the seat is empty the server floats the
-- hull with the same solver the Client uses, so an empty ship stays on the water
-- instead of falling out of the world. The Client takes over when someone boards.
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

local moverAttachment = Instance.new("Attachment")
moverAttachment.Name = "UnmannedMover"
moverAttachment.Parent = VehicleSeat

local buoyancy = Instance.new("AlignPosition")
buoyancy.Name = "UnmannedBuoyancy"
buoyancy.Mode = Enum.PositionAlignmentMode.OneAttachment
buoyancy.Attachment0 = moverAttachment
buoyancy.ApplyAtCenterOfMass = true
buoyancy.ForceLimitMode = Enum.ForceLimitMode.PerAxis
buoyancy.ForceRelativeTo = Enum.ActuatorRelativeTo.World
buoyancy.MaxVelocity = 80
buoyancy.Responsiveness = 12
buoyancy.RigidityEnabled = false
buoyancy.MaxAxesForce = Vector3.zero
buoyancy.Position = moverAttachment.WorldPosition
buoyancy.Enabled = false
buoyancy.Parent = VehicleSeat

local buoyancyForce = Instance.new("VectorForce")
buoyancyForce.Name = "UnmannedBuoyancyForce"
buoyancyForce.Attachment0 = moverAttachment
buoyancyForce.RelativeTo = Enum.ActuatorRelativeTo.World
buoyancyForce.ApplyAtCenterOfMass = true
buoyancyForce.Force = Vector3.zero
buoyancyForce.Parent = VehicleSeat

-- Unmanned, the hull coasts to a stop: drag and keel damping only (no engine, no
-- sail, no rudder). ShipDrive.Acceleration with zero command and zero sail is just that.
local unmannedDrag = Instance.new("VectorForce")
unmannedDrag.Name = "UnmannedDrag"
unmannedDrag.Attachment0 = moverAttachment
unmannedDrag.RelativeTo = Enum.ActuatorRelativeTo.World
unmannedDrag.ApplyAtCenterOfMass = true
unmannedDrag.Force = Vector3.zero
unmannedDrag.Parent = VehicleSeat

local orientation = Instance.new("AlignOrientation")
orientation.Name = "UnmannedOrientation"
orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
orientation.Attachment0 = moverAttachment
orientation.MaxAngularVelocity = 8
orientation.Responsiveness = 12
orientation.RigidityEnabled = false
orientation.MaxTorque = 0
orientation.Enabled = false
orientation.Parent = VehicleSeat

local maxForce = 0
local lastMass = -1

local function refreshLimits()
	local mass = Main.AssemblyMass
	if mass == lastMass then
		return
	end
	lastMass = mass
	maxForce = mass * workspace.Gravity * 4
	buoyancy.MaxAxesForce = Vector3.new(0, maxForce, 0)
	orientation.MaxTorque = mass * 5000
end
refreshLimits()

-- Heading is kept while the ship is unmanned: yaw is taken from the hull when the
-- last player leaves, and the solver's pitch/roll is composed in front of it.
local function headingOf(seat: VehicleSeat): number
	local look = seat.CFrame.LookVector
	return math.atan2(-look.X, -look.Z)
end
local heading = headingOf(VehicleSeat)

local zoneInfo = {
	SpeedMultiplier = 1,
	PhaseMultiplier = 1,
	AmplitudeMultiplier = 1,
	CURRENT_ZONE = nil :: any,
}

local function updateZoneParameters()
	zoneInfo.CURRENT_ZONE = ZoneManager:GetZoneParameters(Main.Position)
end
updateZoneParameters()
local zoneAccumulated = 0

local unmanned = false
local function setUnmanned(active: boolean)
	unmanned = active
	buoyancy.Enabled = false
	buoyancyForce.Force = Vector3.zero
	orientation.Enabled = active
	if not active then
		unmannedDrag.Force = Vector3.zero
	end
end

-- Anti-climb and anti-sink (ShipGuard). The hull's vertical velocity is held while it
-- touches anything outside the ship, and a hull that sinks below its waterline goal
-- is lifted back toward it. Horizontal motion is never touched.
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
	for _, instance in ipairs(Ship:GetDescendants()) do
		if instance:IsA("BasePart") and instance.CanCollide then
			for _, other in ipairs(instance:GetTouchingParts()) do
				if not other:IsDescendantOf(Ship) and not isOccupantPart(other) then
					return true
				end
			end
		end
	end
	return false
end

-- Anti-climb for the UNMANNED hull. It used to run while occupied too, on the theory that
-- "the Client owns the hull then". Two peers writing AssemblyLinearVelocity on the same
-- network-owned assembly is not a share, it is a fight: the client's lift raised the hull
-- and this clamp caught it, every frame. While a player is aboard the driver's client runs
-- the whole guard (it calls the same ResolveVertical), so the server stands down and there
-- is exactly one authority.
RunService.PostSimulation:Connect(function()
	if VehicleSeat.Occupant ~= nil then
		return
	end
	local v = Main.AssemblyLinearVelocity
	local vy = ShipGuard.ResolveVertical(v.Y, Main.Position.Y, nil, touchingOutside)
	if vy ~= v.Y then
		Main.AssemblyLinearVelocity = Vector3.new(v.X, vy, v.Z)
	end
end)

RunService.PostSimulation:Connect(function(dt)
	if VehicleSeat.Occupant ~= nil then
		if unmanned then
			setUnmanned(false)
		end
		return
	end
	if not unmanned then
		setUnmanned(true)
	end

	refreshLimits()
	zoneAccumulated += dt

	-- Coast to a stop: drag on the hull's own velocity (the engine and sail are off).
	local look = VehicleSeat.CFrame.LookVector
	local forward = Vector3.new(look.X, 0, look.Z)
	if forward.Magnitude > 1e-3 then
		forward = forward.Unit
		local drag = ShipDrive.Acceleration(
			Main.AssemblyLinearVelocity,
			forward,
			forward:Cross(Vector3.yAxis),
			0,
			dt,
			Vector3.zero,
			0,
			tuning
		)
		unmannedDrag.Force = drag * Main.AssemblyMass
	end

	local currentZone = zoneInfo.CURRENT_ZONE
	if currentZone and currentZone.Type ~= "Whirlpool" then
		if currentZone.Link then
			zoneInfo.PhaseMultiplier, zoneInfo.SpeedMultiplier, zoneInfo.AmplitudeMultiplier =
				ZoneManager:GetZoneMultipliers(Main.Position, currentZone.Link.Position, currentZone)
		elseif currentZone.Island then
			local radius = currentZone.Radius / 2
			zoneInfo.PhaseMultiplier, zoneInfo.SpeedMultiplier, zoneInfo.AmplitudeMultiplier =
				ZoneManager:GetIslandMultipliers(Main.Position, currentZone.Island.Center.Position, radius)
		end
	end

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
	local targetY, pose, depth = WaveFloat.Solve(
		buoyancyPoints,
		Main.CenterOfMass.Y,
		bottomY,
		boatLength,
		boatWidth,
		baseHeight,
		zoneInfo,
		"ANALYTIC",
		nil,
		now
	)

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
		local here = moverAttachment.WorldPosition
		buoyancy.Enabled = false -- replaced by the PD force below
		-- Draft (WoodenShip's attribute, 0 on Boat) lowers the goal, as in the Client.
		-- Solve returns a HULL CENTRE height and the servo drives the seat attachment, so
		-- convert into the mover's frame (see the note in Ship.Client).
		local draft = Ship:GetAttribute("Draft") or 0
		local goal = here.Y + ((aimY - draft) - Main.Center.WorldPosition.Y)
		buoyancy.Position = Vector3.new(here.X, goal, here.Z)
		-- The guard's reference is the sea surface plus the ride height, less Draft. The
		-- servo goal above is not usable for this: its drag term falls with the hull, so the
		-- goal sinks as the hull sinks and the gap never grows. This reference stays put.
		-- SinkRestOffset: where the hull rests relative to the sea surface, measured at the
-- mover (the seat), which is what ResolveVertical tests. Default is the
		-- ride height less Draft (Boat). WoodenShip sets its own, measured at rest.
		local surface = seaSurfaceAt(zoneInfo, now)
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
		-- Servo authority rises while the hull is below its band, so it can hold a load.
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
		-- Airborne: let gravity bring the hull back down.
		buoyancy.Enabled = false
		buoyancyForce.Force = Vector3.zero
	end
	orientation.CFrame = CFrame.fromEulerAnglesXYZ(0, heading, 0) * pose

	if zoneAccumulated >= 3 then
		zoneAccumulated = 0
		updateZoneParameters()
	end
end)

local lastPlayer: Player? = nil

local function occupantChanged()
	local occupant = VehicleSeat.Occupant
	if occupant then
		setUnmanned(false)
		local player = Players:GetPlayerFromCharacter(occupant.Parent)
		if player then
			if lastPlayer and lastPlayer ~= player then
				local oldClient = lastPlayer.PlayerGui:FindFirstChild("Client")
				if oldClient then
					oldClient:Destroy()
				end
			end

			if not player.PlayerGui:FindFirstChild("Client") then
				local client = Ship:WaitForChild("Client"):Clone()
				local shipReference = Instance.new("ObjectValue")
				shipReference.Name = "Ship"
				shipReference.Value = Ship
				shipReference.Parent = client
				client.Parent = player.PlayerGui
				client.Enabled = true
			end

			for _, instance in ipairs(Ship:GetDescendants()) do
				if instance:IsA("BasePart") and instance:CanSetNetworkOwnership() then
					instance:SetNetworkOwner(player)
				end
			end
			lastPlayer = player
		end
	else
		if lastPlayer then
			local client = lastPlayer.PlayerGui:FindFirstChild("Client")
			if client then
				client:Destroy()
			end
			lastPlayer = nil
		end
		-- Keep the heading the hull has now, then float it unmanned on the server.
		heading = headingOf(VehicleSeat)
		for _, instance in ipairs(Ship:GetDescendants()) do
			if instance:IsA("BasePart") and instance:CanSetNetworkOwnership() then
				instance:SetNetworkOwner(nil)
			end
		end
		setUnmanned(true)
	end
end

-- Authority watchdog: re-establish the invariant above, and publish what it finds so a
-- client can report it without server-only API. `GetNetworkOwner()` returns nil when the
-- server owns the assembly. Throttled to twice a second; costs two property reads.
local authorityChecks, authorityRepairs = 0, 0
local nextAuthorityCheck = 0
RunService.PostSimulation:Connect(function()
	local now = workspace:GetServerTimeNow()
	if now < nextAuthorityCheck then
		return
	end
	nextAuthorityCheck = now + 0.5
	local occupant = VehicleSeat.Occupant
	local wanted = occupant and Players:GetPlayerFromCharacter(occupant.Parent) or nil
	local current = nil
	local ok = pcall(function()
		current = Main:GetNetworkOwner()
	end)
	if not ok then
		return
	end
	authorityChecks += 1
	Ship:SetAttribute("AuthorityOwner", current and current.Name or "server")
	if current == wanted then
		return
	end
	authorityRepairs += 1
	Ship:SetAttribute("AuthorityRepairs", authorityRepairs)
	pcall(function()
		VehicleSeat:SetNetworkOwner(wanted)
	end)
end)

VehicleSeat:GetPropertyChangedSignal("Occupant"):Connect(occupantChanged)
setUnmanned(VehicleSeat.Occupant == nil)
