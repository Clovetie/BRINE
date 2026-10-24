--!nonstrict
--!optimize 2

-- ROADMAP 4.3: placement validation. Owns the octree of every island footprint
-- (cached generated records plus user-authored islands already in workspace.Map),
-- the wide-footprint set (ROADMAP 4.2), and the obstacle query. The generator
-- uses these functions instead of touching the octree directly.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.IslandConfig)
local OctreeModule = require(ReplicatedStorage.Octree)

local RISING_ISLANDS_FOLDER_NAME = "_RisingIslands"

local Placement = {}

-- Octree of every island footprint we must avoid: cached generated records plus
-- any user-authored islands already sitting in workspace.Map.
local islandOctree = OctreeModule.new()

-- ROADMAP 4.2: footprints wider than Placement.MaxIslandRadius are NOT reachable
-- by the octree search radius, so they are tracked here and checked directly.
-- Premade islands can declare a Radius above that bound (e.g. 1400), so the
-- octree alone could miss them.
local largeFootprints: { [any]: boolean } = {}

local function createFootprint(position: Vector3, object: { [string]: any }): any
	local node = islandOctree:CreateNode(position, object)
	if (object.radius or 0) > Config.Placement.MaxIslandRadius then
		largeFootprints[node] = true
	end
	return node
end

local function removeFootprint(node: any)
	islandOctree:RemoveNode(node)
	largeFootprints[node] = nil
end

-- OverlapParams used by the obstacle check. FilterDescendantsInstances is kept
-- fresh before each query so Map/Ocean/rising islands/player characters are not
-- treated as blockers.
local obstacleParams = OverlapParams.new()
obstacleParams.FilterType = Enum.RaycastFilterType.Exclude
obstacleParams.RespectCanCollide = false -- also treat CanQuery-only decor as blockers
obstacleParams.MaxParts = 64 -- bound the query; any hit (> 0) already blocks
obstacleParams.FilterDescendantsInstances = {}

local function refreshObstacleFilters(map: Folder?)
	local exclude = {}

	if map then
		table.insert(exclude, map)
	else
		local mapInstance = Workspace:FindFirstChild("Map")
		if mapInstance then
			table.insert(exclude, mapInstance)
		end
	end

	local ocean = Workspace:FindFirstChild("Ocean")
	if ocean then
		table.insert(exclude, ocean)
	end

	local rising = Workspace:FindFirstChild(RISING_ISLANDS_FOLDER_NAME)
	if rising then
		table.insert(exclude, rising)
	end

	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end

	obstacleParams.FilterDescendantsInstances = exclude
end

-- Placement validation ---------------------------------------------------------

local function hasBlockingObstacle(centerPos: Vector3, radius: number): boolean
	local pl = Config.Placement
	refreshObstacleFilters()
	local parts = Workspace:GetPartBoundsInRadius(centerPos, radius + pl.ObstaclePadding, obstacleParams)
	return #parts > 0
end

-- True when footprint `node` overlaps a spot of footprint `radius` at `centerPos`.
-- `ignoredRecord` is skipped only when it is non-nil and equal to the node's record,
-- so user-authored (seeded) islands with no record still block placement.
local function isBlockingFootprint(node: any, centerPos: Vector3, radius: number, ignoredRecord: any?): boolean
	local object = node.Object or {}
	if ignoredRecord ~= nil and object.record == ignoredRecord then
		return false
	end
	local otherR = object.radius or object.Radius or 0
	return (node.Position - centerPos).Magnitude < radius + otherR + Config.Placement.SpacingPadding
end

-- True if `centerPos` (with footprint `radius`) is a safe, non-overlapping spot.
-- Pass `ignoredRecord` when checking a cached record against the octree that
-- already contains that same record's footprint node.
local function isSpotClear(centerPos: Vector3, radius: number, ignoredRecord: any?, checkObstacles: boolean?): boolean
	local pl = Config.Placement

	-- (1) Island overlap. The octree reaches every footprint up to MaxIslandRadius;
	-- wider footprints (ROADMAP 4.2) are checked directly below.
	local searchRadius = radius + pl.SpacingPadding + pl.MaxIslandRadius
	for _, node in islandOctree:SearchRadius(centerPos, searchRadius) do
		if isBlockingFootprint(node, centerPos, radius, ignoredRecord) then
			return false
		end
	end
	for node in largeFootprints do
		if isBlockingFootprint(node, centerPos, radius, ignoredRecord) then
			return false
		end
	end

	-- (2) Obstacles via broadphase sphere query.
	if checkObstacles ~= false and hasBlockingObstacle(centerPos, radius) then
		return false
	end

	return true
end

-- Removes every footprint (used when the generator clears its state).
function Placement.clearFootprints()
	islandOctree:ClearAllNodes()
	table.clear(largeFootprints)
end

Placement.createFootprint = createFootprint
Placement.removeFootprint = removeFootprint
Placement.refreshObstacleFilters = refreshObstacleFilters
Placement.hasBlockingObstacle = hasBlockingObstacle
Placement.isSpotClear = isSpotClear

return Placement
