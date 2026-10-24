--!native
--!strict
--!optimize 2

-- Ship singleton. The model must contain Main, VehicleSeat, and Client.
local Ship = script.Parent :: Model
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local VehicleSeat = Ship:WaitForChild("VehicleSeat") :: VehicleSeat
Ship:WaitForChild("Main")
VehicleSeat:SetNetworkOwner(nil)

-- An empty ship is anchored so it cannot free-fall past the kill plane (the
-- boat used to fall out of the world about 2 s after play started unless
-- someone sat in it; ROADMAP 2.6). It is unanchored when a player boards and
-- re-anchored when the seat empties.
local function setShipAnchored(anchored: boolean)
	for _, instance in ipairs(Ship:GetDescendants()) do
		if instance:IsA("BasePart") then
			instance.Anchored = anchored
		end
	end
end
setShipAnchored(VehicleSeat.Occupant == nil)

local function registerCollisionGroup(name: string)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
end

registerCollisionGroup("Ship")
registerCollisionGroup("ShipIsland")
PhysicsService:CollisionGroupSetCollidable("Ship", "ShipIsland", false)

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

local lastPlayer: Player? = nil

local function occupantChanged()
	local occupant = VehicleSeat.Occupant
	if occupant then
		setShipAnchored(false)
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
		VehicleSeat:SetNetworkOwner(nil)
		setShipAnchored(true)
	end
end

VehicleSeat:GetPropertyChangedSignal("Occupant"):Connect(occupantChanged)
