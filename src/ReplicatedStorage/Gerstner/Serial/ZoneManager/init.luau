--!strict

local RS = game:GetService('ReplicatedStorage')
local CS = game:GetService('CollectionService')
local RunService = game:GetService('RunService')

local IS_SERVER = RunService:IsServer()
local OctreeModule = require(RS:WaitForChild('Octree'))
local _settings = require(RS.Gerstner.Settings)
local Helper = require(RS.Gerstner.Helper)

local ISLAND_TREE = OctreeModule.new()
local ZONE_TREE = OctreeModule.new()

local clamp = math.clamp
local REFRESH_RATE = 3

local ZONES = {}
local islandNodesByModel: { [Model]: any } = {}
local islandDestroyConnections: { [Model]: RBXScriptConnection } = {}

local function IslandRemoved(Island: Instance)
	if not Island:IsA('Model') then
		return
	end

	local ModelIsland = Island :: Model
	local Node = islandNodesByModel[ModelIsland]
	if Node then
		ISLAND_TREE:RemoveNode(Node)
		islandNodesByModel[ModelIsland] = nil
	end

	local Connection = islandDestroyConnections[ModelIsland]
	if Connection then
		Connection:Disconnect()
		islandDestroyConnections[ModelIsland] = nil
	end
end

local function IslandAdded(Island: Instance)
	if not Island:IsA('Model') then
		return
	end

	local ModelIsland = Island :: Model
	if islandNodesByModel[ModelIsland] or not ModelIsland:IsDescendantOf(workspace) then
		return
	end

	local CenterInstance = ModelIsland:WaitForChild('Center', 1)
	if CenterInstance == nil or not CenterInstance:IsA('BasePart') then
		return
	end
	local Center = CenterInstance :: BasePart

	local Radius = 0
	local RadiusInstance = ModelIsland:FindFirstChild('Radius')
	if RadiusInstance and RadiusInstance:IsA('IntValue') then
		Radius = RadiusInstance.Value
	else
		Radius = (ModelIsland:GetExtentsSize() * Vector3.new(1, 0, 1)).Magnitude / 2
	end

	local Node = ISLAND_TREE:CreateNode(Center.Position, {
		Island = ModelIsland,
		Radius = Radius,
	})
	islandNodesByModel[ModelIsland] = Node
	islandDestroyConnections[ModelIsland] = ModelIsland.Destroying:Connect(function()
		IslandRemoved(ModelIsland)
	end)
end

local function GetMapFolder(): Folder?
	local Map = workspace:FindFirstChild('Map')
	if Map and Map:IsA('Folder') then
		return Map
	end

	if IS_SERVER then
		local NewMap = Instance.new('Folder')
		NewMap.Name = 'Map'
		NewMap.Parent = workspace
		return NewMap
	end

	local WaitedMap = workspace:WaitForChild('Map', 5)
	if WaitedMap and WaitedMap:IsA('Folder') then
		return WaitedMap
	end
	return nil
end

local ZoneManager = {}
export type ZoneParameters = Helper.ZoneParameters
ZoneManager.ISLAND_TREE = ISLAND_TREE
ZoneManager.ZONE_TREE = ZONE_TREE

function ZoneManager:InsertZone(Position: Vector3, ZoneInfo: Helper.ZoneParameters): OctreeModule.Node<Helper.ZoneParameters>?
	local ExistingZone = ZONE_TREE:GetNearest(Position, ZoneInfo.Radius * 2, 1)
	if ExistingZone[1] ~= nil then
		return nil
	end

	local NODE = ZONE_TREE:CreateNode(Position, ZoneInfo)
	if ZoneInfo.Link then
		ZoneInfo.Link.Destroying:Once(function()
			ZONE_TREE:RemoveNode(NODE)
		end)
	end

	if IS_SERVER == true then
		script.EditZone:FireAllClients('Insert', Position, ZoneInfo)
	elseif ZoneInfo.Link then
		local Link = ZoneInfo.Link
		Link.AttributeChanged:Connect(function(Attribute: string)
			if Attribute == 'DestroyNode' then
				ZONE_TREE:RemoveNode(NODE)
				script.ZoneUpdated:Fire()
			elseif Attribute == 'Despawn' then
				NODE.Object.FullDecayAt = workspace:GetServerTimeNow() + ZoneInfo.DissolveTime
				NODE.Object.Despawn = true

				script.ZoneUpdated:Fire()
			end
		end)
	end

	return NODE
end

function ZoneManager:RemoveZone(Node: OctreeModule.Node<Helper.ZoneParameters>)
	Node.Object.Link:SetAttribute('DestroyNode', true)
	ZONE_TREE:RemoveNode(Node)
end

--[[
	Returns the parameters of the zone or island that overlaps the position, prioritizing custom zones over islands
	Should be called sparingly, as every node in the 2 octrees will be iterated over
]]
function ZoneManager:GetZoneParameters(Position: Vector3): Helper.ZoneParameters?

	local ZoneNodes = ZONE_TREE:GetAllNodes()
	for i, Node in ZoneNodes do
		local Data = Node.Object
		local NodePosition = Data.Link.Position
		if (NodePosition - Position).Magnitude < Data.Radius then
			return Data
		end
	end

	local IslandNodes = ISLAND_TREE:GetAllNodes()
	for i, Node in IslandNodes do
		local Data = Node.Object
		local NodePosition = Node.Position

		if (NodePosition - Position).Magnitude < Data.Radius then
			return Data:: any
		end
	end
	return nil
end

--[[
	Fetches the wave parameter multipliers for a specified zone.
]]
function ZoneManager:GetZoneMultipliers(Point: Vector3, ZonePosition: Vector3, ZoneParameters: Helper.ZoneParameters): (number, number, number, boolean)
	return Helper.GetZoneMultipliers(Point, ZonePosition, ZoneParameters)
end

--[[
	Fetches the wave parameter multipliers for a specified island zone.
]]
function ZoneManager:GetIslandMultipliers(Point: Vector3, Island: any, Radius: number): (number, number, number, boolean, number)
	return Helper.GetIslandMultipliers(Point, Island, Radius)
end

--[[
	Updates all nodes in the 'ZONE' tree.
]]
function ZoneManager.UpdateAllNodes()
	local Nodes = ZONE_TREE:GetAllNodes()
	for i, Node in Nodes do
		local Data = Node.Object
		ZONE_TREE:ChangeNodePosition(Node, Data.Link.Position)
	end
end

-- // Main
local Accumulated = 0
RunService.PostSimulation:Connect(function(dt)
	Accumulated += dt
	if Accumulated >= REFRESH_RATE then
		Accumulated = 0
		ZoneManager.UpdateAllNodes()
	end
end)

CS:GetInstanceAddedSignal('Island'):Connect(function(Island)
	IslandAdded(Island)
end)
CS:GetInstanceRemovedSignal('Island'):Connect(function(Island)
	IslandRemoved(Island)
end)
for i, Island in CS:GetTagged('Island') do
	IslandAdded(Island)
end

local Map = GetMapFolder()
if Map then
	for i, Island in Map:GetChildren() do
		IslandAdded(Island)
	end
	Map.ChildAdded:Connect(function(Island)
		IslandAdded(Island)
	end)
	Map.ChildRemoved:Connect(function(Island)
		IslandRemoved(Island)
	end)
end

if IS_SERVER == false then
	script.EditZone.OnClientEvent:Connect(function(Type, ...)
		if Type == 'Insert' then
			ZoneManager:InsertZone(...)
		end
		script.ZoneUpdated:Fire()
	end)
end

ZoneManager.ZoneUpdated = script.ZoneUpdated.Event

return ZoneManager
