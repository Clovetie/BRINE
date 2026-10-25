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
local ZoneManager = require(ReplicatedStorage.Gerstner.Serial.ZoneManager)

local VehicleSeat = Ship:WaitForChild("VehicleSeat") :: VehicleSeat
local Main = Ship:WaitForChild("Main") :: BasePart
VehicleSeat:SetNetworkOwner(nil)

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
	buoyancy.Enabled = active
	orientation.Enabled = active
end

-- Anti-climb (ship must not ride up fixed objects). While the hull touches a part
-- outside the ship and is moving up, cancel the upward velocity. Fixed objects
-- block the hull; the buoyancy servo still settles it on the water.
local function touchingOutside(): boolean
	for _, instance in ipairs(Ship:GetDescendants()) do
		if instance:IsA("BasePart") and instance.CanCollide then
			for _, other in ipairs(instance:GetTouchingParts()) do
				if not other:IsDescendantOf(Ship) then
					return true
				end
			end
		end
	end
	return false
end

RunService.PostSimulation:Connect(function()
	local v = Main.AssemblyLinearVelocity
	if v.Y > 0 and touchingOutside() then
		Main.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)
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

	local targetY, pose, depth = WaveFloat.Solve(
		buoyancyPoints,
		Main.CenterOfMass.Y,
		Main.Center.WorldPosition.Y,
		boatLength,
		boatWidth,
		baseHeight,
		zoneInfo,
		"ANALYTIC",
		nil,
		workspace:GetServerTimeNow()
	)

	if targetY ~= nil then
		local here = moverAttachment.WorldPosition
		buoyancy.Enabled = true
		buoyancy.MaxAxesForce = Vector3.new(0, maxForce * (1 + depth / 10), 0)
		buoyancy.Position = Vector3.new(here.X, targetY, here.Z)
	else
		-- Airborne: let gravity bring the hull back down.
		buoyancy.Enabled = false
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

VehicleSeat:GetPropertyChangedSignal("Occupant"):Connect(occupantChanged)
setUnmanned(VehicleSeat.Occupant == nil)
