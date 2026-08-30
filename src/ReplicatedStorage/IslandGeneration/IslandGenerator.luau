--!nonstrict
--!optimize 2

--[[
	IslandGenerator
	===============
	Scatters PREMADE islands into the world. Islands are authored as complete
	Models inside ServerStorage.Islands (a folder of biome folders; each biome
	folder may contain arbitrarily-nested folders of island Models). The
	generator does NOT generate geometry, noise, or structures - it only
	discovers templates, picks them, and clones them into workspace.Map with the
	exact island contract ZoneManager / Helper already expect.

	Biomes are auto-discovered from the subfolders of the Islands root (see
	IslandConfig.BiomeWeights for optional weight overrides). A biome folder with
	no island Models is skipped; a Model sitting directly under the root is
	assigned Config.DefaultBiome.

	Determinism: all randomness (grid jitter, biome/template pick, yaw) derives
	from Random.new(worldSeed + index) and a dedicated placement stream
	Random.new(worldSeed - 101). Same world seed + same Islands content =>
	same world, every run. math.random() is only used by the optional ad-hoc
	PlaceOne() fallback; it is never used on the deterministic scatter path.

	Collision safety ("NEVER collides"): every candidate is validated BEFORE the
	island is parented into the world. A spot is clear only if:
		(a) it is far enough from every already-placed island (octree), and
		(b) it overlaps no non-ocean / non-map BaseParts (boats, players, props,
		    baseplate...) via Workspace:GetPartBoundsInRadius.
	If a candidate collides, the position/template is re-rolled
	(Placement.MaxPlacementAttempts) instead of forcing an island into a bad spot.

	References (official docs):
		ServerStorage         https://create.roblox.com/docs/reference/engine/classes/ServerStorage
		Instance              https://create.roblox.com/docs/reference/engine/classes/Instance
		Model                 https://create.roblox.com/docs/reference/engine/classes/Model
		CollectionService     https://create.roblox.com/docs/reference/engine/classes/CollectionService
		WorldRoot bounds      https://create.roblox.com/docs/reference/engine/classes/WorldRoot
		OverlapParams         https://create.roblox.com/docs/reference/engine/datatypes/OverlapParams
]]

local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.IslandConfig)
local OctreeModule = require(ReplicatedStorage.Octree)

local PLANE_Y = Config.PlaneOffset
local TAG = "Island"

-- Module state -----------------------------------------------------------------

local IslandGenerator = {}

-- Octree of already-placed island centers + radii (used for overlap rejection).
local islandOctree = OctreeModule.new()
-- The island Models this generator placed (destroyed wholesale on ClearGenerated).
local createdModels = {}
-- Built once from ServerStorage.Islands; entry = { name, weight, templates }.
local catalog = nil
-- Whether we have already seeded the octree with the islands that were present
-- in workspace.Map when the generator first ran (idempotency guard).
local mapSeeded = false
-- Bumped on ClearGenerated to abort any in-flight generation threads.
local generationToken = 0

-- OverlapParams used by the obstacle check: find every BasePart that is NOT a
-- descendant of Map (island container) or Ocean (water planes). Any such part
-- overlapping a candidate footprint means the spot is blocked.
local obstacleParams = OverlapParams.new()
obstacleParams.RespectCanCollide = false -- also treat CanQuery-only decor as blockers
obstacleParams.MaxParts = 64 -- bound the query; any hit (> 0) already blocks
-- ExcludeInstances is assigned in ensureMapFolder() once Map/Ocean exist.
obstacleParams.ExcludeInstances = {}

-- Small helpers ----------------------------------------------------------------

local function weightedPickEntry(entries: { any }, rng: Random): any
	local total = 0
	local weights = {}
	for i, entry in ipairs(entries) do
		local w = entry.weight or Config.DEFAULT_WEIGHT
		if w > 0 then
			total += w
			weights[i] = w
		end
	end
	if total <= 0 then
		return entries[rng:NextInteger(1, #entries)]
	end
	local roll = rng:NextNumber(0, total)
	local cursor = 0
	for i, entry in ipairs(entries) do
		cursor += weights[i] or 0
		if roll <= cursor then
			return entry
		end
	end
	return entries[#entries]
end

-- Reads the world seed from the SAME IntValue the ocean uses
-- (ReplicatedStorage.Gerstner.Settings.Seed). Settings reseeds that value once
-- when it is 0 and persists it, so by the time we require Settings the value is
-- stable across server restarts. A fixed fallback keeps us deterministic even if
-- the IntValue is somehow missing or zero.
local function getWorldSeed(): number
	local seedValue = 0
	local ok, valueScript = pcall(function()
		return ReplicatedStorage.Gerstner.Settings:FindFirstChild("Seed")
	end)
	if ok and valueScript and valueScript:IsA("IntValue") and valueScript.Value ~= 0 then
		seedValue = valueScript.Value
	else
		seedValue = 7919
	end
	return seedValue
end

-- workspace.Map is the folder the ocean depth raycasts include and ZoneManager
-- scans; the generator must place islands there. It also tells the obstacle
-- query which folders to ignore so it never flags water/terrain as an obstacle.
local function ensureMapFolder(): Folder
	local map = Workspace:FindFirstChild("Map")
	if not map then
		map = Instance.new("Folder")
		map.Name = "Map"
		map.Parent = Workspace
	end
	local exclude = { map }
	local ocean = Workspace:FindFirstChild("Ocean")
	if ocean then
		table.insert(exclude, ocean)
	end
	obstacleParams.ExcludeInstances = exclude
	return map
end

-- Catalog / discovery -----------------------------------------------------------

-- Collects every premade island Model under `folder`, recursing through nested
-- folders of any depth. We deliberately do NOT descend into Models: a model's
-- children are island components (e.g. a dock/ruin submodel), not separate
-- island templates.
local function collectTemplates(folder: Instance, out: { Model })
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			table.insert(out, child)
		elseif child:IsA("Folder") then
			collectTemplates(child, out)
		end
		-- Ignore any other instance type (stray Parts, StringValues, ...).
	end
end

-- Builds the biome catalog from ServerStorage.Islands.
--   * Each Folder directly under the root = a biome (its Name).
--   * Models directly under the root = Config.DefaultBiome (edge case).
--   * Biomes with no island Models are skipped (edge case).
--   * Optional weights come from Config.BiomeWeights; weight <= 0 removes it.
local function buildCatalog()
	local root = ServerStorage:FindFirstChild(Config.PremadeIslandsRoot)
	if not root then
		catalog = {}
		return catalog
	end

	local entries = {}

	-- Loose Models directly under the root.
	local rootModels = {}
	for _, child in root:GetChildren() do
		if child:IsA("Model") then
			table.insert(rootModels, child)
		end
	end
	if #rootModels > 0 then
		local name = Config.DefaultBiome
		entries[name] = {
			name = name,
			weight = Config.BiomeWeights[name] or Config.DEFAULT_WEIGHT,
			templates = rootModels,
		}
	end

	-- Biome folders.
	for _, child in root:GetChildren() do
		if child:IsA("Folder") then
			local templates = {}
			collectTemplates(child, templates)
			if #templates > 0 then
				local name = child.Name
				entries[name] = {
					name = name,
					weight = Config.BiomeWeights[name] or Config.DEFAULT_WEIGHT,
					templates = templates,
				}
			end
		end
	end

	catalog = {}
	for _, entry in entries do
		if entry.weight > 0 then
			table.insert(catalog, entry)
		end
	end
	return catalog
end

-- Island contract helpers ------------------------------------------------------

-- Radius for a premade island model: Radius IntValue first, then the XZ
-- bounding-box half (matching ZoneManager's own fallback), then DefaultRadius.
local function modelRadius(model: Model): number
	local radiusInst = model:FindFirstChild(Config.RadiusValueName)
	if radiusInst and radiusInst:IsA("IntValue") and radiusInst.Value > 0 then
		return radiusInst.Value
	end
	local extents = model:GetExtentsSize() * Vector3.new(1, 0, 1)
	local bboxRadius = extents.Magnitude / 2
	if bboxRadius > 1 then
		return bboxRadius
	end
	return Config.DefaultRadius
end

-- Returns the island's Center BasePart, creating a contract-compliant one at the
-- model's bounding-box center if the template has none. The returned part is the
-- model's PrimaryPart.
local function ensureCenter(model: Model): BasePart
	local center = model:FindFirstChild(Config.CenterPartName)
	if center and center:IsA("BasePart") then
		center.Anchored = true
		center.CanCollide = false
		model.PrimaryPart = center
		return center
	end

	local cf = model:GetBoundingBox() -- returns (CFrame, Vector3); we want the center CFrame
	local part = Instance.new("Part")
	part.Name = Config.CenterPartName
	part.Size = Config.CenterPartSize
	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 1
	part.Position = cf.Position
	part.Parent = model
	model.PrimaryPart = part
	return part
end

-- Collision check --------------------------------------------------------------

-- True if `centerPos` (with footprint `radius`) is a safe, non-overlapping spot:
--   (1) no already-placed island centre is too close, and
--   (2) no non-ocean/non-map part (boat, player, prop, baseplate) overlaps it.
local function isSpotClear(centerPos: Vector3, radius: number): boolean
	local pl = Config.Placement

	-- (1) Island overlap via octree.
	local searchRadius = radius + pl.SpacingPadding + pl.MaxIslandRadius
	for _, node in islandOctree:SearchRadius(centerPos, searchRadius) do
		local otherR = node.Object.radius or 0
		if (node.Position - centerPos).Magnitude < radius + otherR + pl.SpacingPadding then
			return false
		end
	end

	-- (2) Obstacles via broadphase sphere query.
	local parts = Workspace:GetPartBoundsInRadius(
		centerPos,
		radius + pl.ObstaclePadding,
		obstacleParams
	)
	if #parts > 0 then
		return false
	end

	return true
end

-- Placement --------------------------------------------------------------------

-- Clones `template`, lays it down at `centerPos` (waterline Y = PLANE_Y), and
-- parents it into workspace.Map with the island contract + "Island" tag. Returns
-- the placed Model, or nil on failure.
local function placeTemplate(template: Model, biomeName: string, centerPos: Vector3, yaw: number): Model?
	if not template or not template:IsA("Model") then
		return nil
	end

	local clone = template:Clone()
	local center = ensureCenter(clone)
	local radius = modelRadius(template)

	-- Reposition the clone so its Center part lands exactly on centerPos,
	-- preserving the template's internal offsets and applying a yaw rotation.
	local pivot = clone.Pivot
	local offset = center.Position - pivot.Position
	local rotation = CFrame.Angles(0, yaw, 0)
	local newPivot = centerPos - (rotation * offset)
	clone:PivotTo(CFrame.new(newPivot) * rotation)

	-- Anchor the whole island so it is static and never sinks/fells in the ocean.
	-- See Config.Placement.AnchorPlacedIslands.
	if Config.Placement.AnchorPlacedIslands then
		for _, descendant in clone:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
			end
		end
	end

	-- Ensure a Radius IntValue (ZoneManager reads it on tag).
	if not clone:FindFirstChild(Config.RadiusValueName) then
		local rv = Instance.new("IntValue")
		rv.Name = Config.RadiusValueName
		rv.Value = math.round(radius)
		rv.Parent = clone
	end

	-- Parent into Map first, then tag, so ZoneManager indexes a fully-parented
	-- island when the "Island" tag fires.
	clone.Parent = ensureMapFolder()
	clone:SetAttribute("Biome", biomeName)
	clone:SetAttribute("Premade", template.Name)
	CollectionService:AddTag(clone, TAG)

	islandOctree:CreateNode(Vector3.new(centerPos.X, PLANE_Y, centerPos.Z), { radius = radius })
	table.insert(createdModels, clone)
	return clone
end

-- Seeds the placement octree with any islands already present in workspace.Map at
-- startup (e.g. user-dropped anchors or a previous run) so the scatter never
-- overlaps them.
local function seedOctreeFromMap(map: Folder)
	for _, child in map:GetChildren() do
		if child:IsA("Model") then
			local center = child:FindFirstChild(Config.CenterPartName)
			local pos: Vector3
			if center and center:IsA("BasePart") then
				pos = center.Position
			else
				pos = child:GetPivot().Position
			end
			local radius = modelRadius(child)
			islandOctree:CreateNode(Vector3.new(pos.X, PLANE_Y, pos.Z), { radius = radius })
		end
	end
	mapSeeded = true
end

-- Public API -------------------------------------------------------------------

-- Rebuilds and returns the biome catalog currently found under ServerStorage.
function IslandGenerator.GetCatalog()
	if catalog == nil then
		buildCatalog()
	end
	return catalog
end

-- Places a single random premade island at `centerPos`. Useful for dropping an
-- island at runtime (e.g. via a debug/admin tool). Returns the placed Model.
function IslandGenerator.PlaceOne(centerPos: Vector3, index: number): Model?
	local worldSeed = getWorldSeed()
	local rng = Random.new(worldSeed + (index or math.random(1, 100000)))

	-- NOTE: for deterministic single placements callers should pass a stable
	-- index; the fallback here uses math.random which is fine for ad-hoc drops
	-- but not for the deterministic scatter pass (that uses its own seed).
	local map = ensureMapFolder()
	-- Respect any islands already in the world (seed the octree once).
	if not mapSeeded then
		seedOctreeFromMap(map)
	end
	local catalogList = IslandGenerator.GetCatalog()
	if #catalogList == 0 then
		return nil
	end
	local entry = weightedPickEntry(catalogList, rng)
	local template = entry.templates[rng:NextInteger(1, #entry.templates)]
	local radius = modelRadius(template)
	if not isSpotClear(centerPos, radius) then
		return nil
	end
	local yaw = rng:NextNumber(0, math.pi * 2)
	return placeTemplate(template, entry.name, centerPos, yaw)
end

-- Main scatter pass. Builds (or rebuilds) the catalog, seeds the octree with any
-- existing islands, then walks a jittered grid and places one premade island per
-- clear cell. Colliding cells are re-rolled rather than overlapped.
function IslandGenerator.Generate()
	local token = generationToken + 1
	generationToken = token

	local catalogList = IslandGenerator.GetCatalog()
	if #catalogList == 0 then
		warn("[IslandGenerator] No premade islands found under ServerStorage." .. Config.PremadeIslandsRoot .. ".")
		return
	end

	local map = ensureMapFolder()
	if not mapSeeded then
		seedOctreeFromMap(map)
	end

	local worldSeed = getWorldSeed()
	local rng = Random.new(worldSeed - 101)
	local pl = Config.Placement
	local cell = pl.CellSize
	local halfCells = math.ceil(pl.WorldRadius / cell)

	local placed = 0
	for gx = -halfCells, halfCells do
		for gz = -halfCells, halfCells do
			if generationToken ~= token then
				return
			end
			local baseX, baseZ = gx * cell, gz * cell
			for _ = 1, pl.MaxPlacementAttempts do
				if generationToken ~= token then
					return
				end
				local x = baseX + rng:NextNumber(-cell * pl.GridJitter, cell * pl.GridJitter)
				local z = baseZ + rng:NextNumber(-cell * pl.GridJitter, cell * pl.GridJitter)
				local distOrigin = math.sqrt(x * x + z * z)
				if distOrigin > pl.WorldRadius then
					continue
				end
				if distOrigin < pl.SpawnSafetyRadius then
					continue
				end

				local pos = Vector3.new(x, PLANE_Y, z)
				local entry = weightedPickEntry(catalogList, rng)
				local template = entry.templates[rng:NextInteger(1, #entry.templates)]
				local radius = modelRadius(template)

				if isSpotClear(pos, radius) then
					local yaw = rng:NextNumber(0, math.pi * 2)
					local ok, result = pcall(placeTemplate, template, entry.name, pos, yaw)
					if ok and result then
						placed += 1
						task.wait()
						break -- island placed for this cell
					elseif not ok then
						warn("[IslandGenerator] failed to place '" .. template.Name .. "': " .. tostring(result))
					end
				end
				-- else: collided -> re-roll position/template (find a new spot).
				task.wait()
			end
		end
	end

	print("[IslandGenerator] scatter complete: " .. placed .. " island(s) placed.")
end

-- Removes every island this generator placed and resets the placement octree.
-- Any user-dropped anchors present in workspace.Map are preserved (we only
-- destroy what we put there). Call this then Generate() to rebuild.
function IslandGenerator.ClearGenerated()
	generationToken = generationToken + 1
	for _, model in createdModels do
		if model and model.Parent then
			model:Destroy()
		end
	end
	table.clear(createdModels)
	islandOctree:ClearAllNodes()
	mapSeeded = false
	catalog = nil -- force re-discovery on next Generate
end

return IslandGenerator
