--!nonstrict
--!optimize 2

--[[
	IslandGenerator
	===============
	Deterministic, server-authoritative island generator.

	Pipeline:
		1. Resolve anchors: user-placed "Island" models (Center + Radius) are
		   used verbatim; if procedural placement is enabled, extra anchors are
		   scattered on a jittered grid with Octree overlap rejection.
		2. For each island index, derive a Random = Random.new(worldSeed + index).
		   All choices (biome, type, radius, structures) come from that Random;
		   the terrain heightmap comes from deterministic math.noise seeded per
		   island. Same seed + same index => identical island, every run.
		3. Build one heightmap (fBm + radial falloff), tint vertices by biome /
		   height / slope, emit ONE closed EditableMesh (top surface + side
		   skirt + bottom fan) and turn it into a MeshPart via
		   AssetService:CreateMeshPartAsync. The mesh is authored in LOCAL space
		   around the island center (water plane at local Y = 0), then the part
		   is placed at CFrame.new(center.X, PLANE_Y, center.Z).
		4. Parent the terrain to an "Island" Model under workspace.Map (the folder
		   the ocean depth raycasts include) and tag it "Island" so ZoneManager
		   indexes it. The Model keeps its Center (PrimaryPart) + Radius IntValue.
		5. Spawn weighted anchored structures (wreck/ruins/dock) and floating
		   debris (barrels/crates/buoys) that bob with the REAL waves via
		   HeightLookup + BoatManager.CalculateBuoyancy.

	Nothing here trusts the client. There are no RemoteEvents.
]]

local AssetService = game:GetService("AssetService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(script.Parent.IslandConfig)
local Settings = require(ReplicatedStorage.Gerstner.Settings)
-- Floating debris samples the real wave surface through BoatManager, which
-- itself drives HeightLookup.Lookup internally - we reuse the exact same
-- CalculateBuoyancy path the boats use rather than inventing a wave system.
local BoatManager = require(ReplicatedStorage.Gerstner.BoatManager)
local OctreeModule = require(ReplicatedStorage.Octree)

local PLANE_Y = Config.PlaneOffset -- water surface height (25 by default)
local TAG = "Island"

-- Raycast params -------------------------------------------------------------

-- Raycasts that are meant to hit island terrain / seabed.
local mapRaycastParams = RaycastParams.new()
mapRaycastParams.FilterType = Enum.RaycastFilterType.Include

-- Raycasts meant to detect boats / players / other props (i.e. anything that
-- is NOT the island terrain and NOT the ocean surface). Both Map and Ocean are
-- excluded; a hit therefore means a real obstacle.
local obstacleRaycastParams = RaycastParams.new()
obstacleRaycastParams.FilterType = Enum.RaycastFilterType.Exclude

local function ensureMapFolder(): Folder
	local map = Workspace:FindFirstChild("Map")
	if not map then
		map = Instance.new("Folder")
		map.Name = "Map"
		map.Parent = Workspace
	end
	mapRaycastParams.FilterDescendantsInstances = { map }

	local exclude = { map }
	local ocean = Workspace:FindFirstChild("Ocean")
	if ocean then
		table.insert(exclude, ocean)
	end
	obstacleRaycastParams.FilterDescendantsInstances = exclude
	return map
end

-- Module state ---------------------------------------------------------------

local IslandGenerator = {}

local islandTree = OctreeModule.new() -- island centers, for overlap rejection
local structureTree = OctreeModule.new() -- structure footprints

local createdModels = {} -- whole island Models we own (procedural)
local createdInstances = {} -- instances parented into user anchor models
local floatingObjects = {} -- { root = Part, attachments = {Attachment}, rideHeight = n }
local floatingCursor = 1

local heartbeatConnection: RBXScriptConnection? = nil
local generationToken = 0 -- bumped on ClearGenerated to abort stale threads

-- Small helpers ---------------------------------------------------------------

local clamp = math.clamp

local function fLerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function smooth01(t: number): number
	t = clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Fractal Brownian motion: stacked octaves of math.noise -> ~[-1, 1].
-- math.noise is deterministic and seedable via its third argument, so the whole
-- heightmap is reproducible from (seed) alone.
local function fbm(x: number, y: number, seed: number, octaves: number): number
	local total = 0
	local amplitude = 1
	local frequency = 1
	local amplitudeSum = 0
	for _ = 1, octaves do
		total += math.noise(x * frequency, y * frequency, seed) * amplitude
		amplitudeSum += amplitude
		amplitude *= 0.5
		frequency *= 2
	end
	return total / amplitudeSum
end

-- Weighted pick ---------------------------------------------------------------

-- Picks a key from a { [key] = weight } dictionary using `rng`.
-- Missing weight -> DEFAULT_WEIGHT; weight <= 0 skips the entry (an explicit 0
-- removes it). If every entry is <= 0 we fall back to a uniform pick over all
-- keys so a misconfigured pool never blocks generation.
local function weightedPickKey(pool: { [string]: number }, rng: Random): string?
	local keys = {}
	local weights = {}
	local total = 0
	for key, weight in pool do
		local w = weight
		if w == nil then
			w = Config.DEFAULT_WEIGHT
		end
		if w > 0 then
			total += w
			table.insert(keys, key)
			weights[key] = w
		end
	end

	if total <= 0 then
		local all = {}
		for key in pool do
			table.insert(all, key)
		end
		if #all == 0 then
			return nil
		end
		return all[rng:NextInteger(1, #all)]
	end

	local roll = rng:NextNumber(0, total)
	local cursor = 0
	for _, key in keys do
		cursor += weights[key]
		if roll <= cursor then
			return key
		end
	end
	return keys[#keys]
end

-- Effective weight of a config category (DEFAULT_WEIGHT when omitted).
local function categoryWeight(entry: any): number
	local w = entry and entry.Weight
	if w == nil then
		return Config.DEFAULT_WEIGHT
	end
	return w
end

-- World seed -----------------------------------------------------------------

-- Reads the world seed from the SAME IntValue the ocean uses
-- (ReplicatedStorage.Gerstner.Settings.Seed). Settings reseeds that value once
-- when it is 0 and persists it, so by the time we require Settings the value is
-- stable across server restarts. A fixed constant fallback keeps us
-- deterministic even if the IntValue is somehow missing or zero.
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

-- Terrain heightmap (local space: water plane at Y = 0) ----------------------

-- Height at local offset (lx, lz). Negative = below the water plane.
local function terrainHeight(
	lx: number,
	lz: number,
	radius: number,
	maxHeight: number,
	kind: string,
	seed: number
): number
	local d = math.sqrt(lx * lx + lz * lz)
	local edge01 = clamp(d / radius, 0, 1)

	local noiseScale = radius * 1.4 -- larger islands -> broader features
	local hills = fbm(lx / noiseScale + 100, lz / noiseScale + 100, seed, Config.Generation.NoiseOctaves)
	local detail = fbm(lx / (radius * 0.35), lz / (radius * 0.35), seed + 50, 3) * 0.15
	local relief = (hills + detail) * 0.5 + 0.5 -- [0,1]

	if kind == "Atoll" then
		-- Ring of low land around a submerged lagoon.
		local rim = smooth01(1 - math.abs(edge01 - 0.82) / 0.22) -- peak ring ~0.82R
		local lagoonFloor = -3.5 + hills * 0.4
		local rimHeight = maxHeight * rim * (0.75 + 0.25 * relief)
		local shelf = -Config.ShelfDepth * smooth01(edge01)
		return math.max(lagoonFloor, rimHeight) + shelf * (1 - rim)
	end

	-- Normal island: dome of hills sloping into the sea.
	local dome = 1 - edge01 ^ 1.6
	local height = maxHeight * dome * (0.45 + 0.55 * relief)

	-- Flatten a beach band just inside the rim (shoreline instead of cliff).
	local shoreBand = smooth01((edge01 - 0.86) / 0.14)
	height = fLerp(height, math.min(height, 0.6), shoreBand * 0.8)

	-- Past the rim, sink to the underwater shelf floor.
	height = fLerp(height, -Config.ShelfDepth, smooth01((edge01 - 0.94) / 0.06))

	return height
end

-- Vertex color from biome / height / slope -----------------------------------

local function terrainColor(
	height: number,
	normalY: number,
	biome: any,
	maxHeight: number,
	jitter: number
): Color3
	local c = biome.Colors

	if height < 0 then
		-- Underwater shelf: sand darkening toward the underwater ground tone.
		local t = clamp(-height / Config.ShelfDepth, 0, 1)
		local col = c.Sand:Lerp(c.Underwater, t)
		return Color3.new(clamp(col.R + jitter, 0, 1), clamp(col.G + jitter, 0, 1), clamp(col.B + jitter, 0, 1))
	end

	-- Beach band right above the waterline.
	if height <= biome.BeachHeight then
		local t = smooth01((height - biome.BeachHeight * 0.4) / (biome.BeachHeight * 0.6))
		local col = c.Sand:Lerp(c.Grass, t)
		return Color3.new(clamp(col.R + jitter, 0, 1), clamp(col.G + jitter, 0, 1), clamp(col.B + jitter, 0, 1))
	end

	-- Inland: grass blending to rock by altitude...
	local altitude = height / maxHeight
	local base = c.Grass:Lerp(c.Rock, smooth01((altitude - biome.RockLine) / 0.25))

	-- ...and bare rock on steep faces regardless of height.
	local rockSteep = smooth01((biome.RockSteepness - normalY) / 0.18)
	base = base:Lerp(c.Rock, rockSteep)

	-- Snow caps above the snowline, but only on gentle slopes.
	if c.Snow and biome.SnowLine and altitude > biome.SnowLine then
		local snowT = smooth01((altitude - biome.SnowLine) / 0.2) * (normalY > 0.75 and 1 or 0.25)
		base = base:Lerp(c.Snow, snowT)
	end

	return Color3.new(
		clamp(base.R + jitter, 0, 1),
		clamp(base.G + jitter, 0, 1),
		clamp(base.B + jitter, 0, 1)
	)
end

-- EditableMesh construction ---------------------------------------------------

-- Builds the closed island mesh in LOCAL space (origin = island center at water
-- level). Layout:
--   * Top surface: grid over the bounding square; vertices past radius*1.08 are
--     omitted so the footprint is round, not a square.
--   * Skirt: a wall around every boundary vertex drops to -SkirtDepth so the
--     terrain is watertight from below and the ocean's depth ray (15 studs)
--     always hits solid ground.
--   * Bottom: a triangle fan at -SkirtDepth closes the solid.
-- Colors are applied per-face (AddColor + SetFaceColors) which gives smooth
-- vertex-color interpolation on the rendered MeshPart.
local function buildIslandMesh(
	radius: number,
	maxHeight: number,
	kind: string,
	biome: any,
	seed: number,
	resolution: number,
	shouldYield: any
): any
	local em = AssetService:CreateEditableMesh({ FixedSize = true })

	local N = resolution
	local extent = radius * 1.08
	local spacing = (extent * 2) / (N - 1)

	local function gridToLocal(g: number): number
		return (g - (N - 1) / 2) * spacing
	end

	local function active(gx: number, gz: number): boolean
		local lx = gridToLocal(gx)
		local lz = gridToLocal(gz)
		return math.sqrt(lx * lx + lz * lz) <= radius * 1.08
	end

	-- Top vertices -------------------------------------------------------------
	local top = table.create(N)
	for gz = 0, N - 1 do
		top[gz] = table.create(N)
		for gx = 0, N - 1 do
			if active(gx, gz) then
				local lx = gridToLocal(gx)
				local lz = gridToLocal(gz)
				local h = terrainHeight(lx, lz, radius, maxHeight, kind, seed)
				top[gz][gx] = em:AddVertex(Vector3.new(lx, h, lz))
			end
			if (gz * N + gx) % Config.Generation.VertexBudgetPerFrame == 0 then
				shouldYield()
			end
		end
	end

	-- Color attribute cache (quantized so similar colors share an attribute).
	local colorIdCache = {}
	local function getColorId(col: Color3): number
		local key = math.round(col.R * 255) * 65536 + math.round(col.G * 255) * 256 + math.round(col.B * 255)
		local id = colorIdCache[key]
		if not id then
			id = em:AddColor(col, 1)
			colorIdCache[key] = id
		end
		return id
	end

	-- Approximate up-facing component of the surface normal at a grid vertex,
	-- used to detect steep cliffs (which paint as rock).
	local function normalYAt(gx: number, gz: number): number
		local hl = top[gz] and top[gz][gx - 1]
		local hr = top[gz] and top[gz][gx + 1]
		local hd = top[gz - 1] and top[gz - 1][gx]
		local hu = top[gz + 1] and top[gz + 1][gx]
		if not (hl and hr and hd and hu) then
			return 1
		end
		local dx = em:GetPosition(hr) - em:GetPosition(hl)
		local dz = em:GetPosition(hu) - em:GetPosition(hd)
		return math.abs(dz:Cross(dx).Unit.Y)
	end

	-- Top triangles (winding matches the ocean Setup: up-facing) ---------------
	local faceCount = 0
	for gz = 0, N - 2 do
		for gx = 0, N - 2 do
			local v1 = top[gz] and top[gz][gx]
			local v2 = top[gz + 1] and top[gz + 1][gx]
			local v3 = top[gz] and top[gz][gx + 1]
			local v4 = top[gz + 1] and top[gz + 1][gx + 1]
			if v1 and v2 and v3 and v4 then
				local midLX = gridToLocal(gx + 0.5)
				local midLZ = gridToLocal(gz + 0.5)
				local midH = terrainHeight(midLX, midLZ, radius, maxHeight, kind, seed)
				local nY = clamp(normalYAt(gx, gz), 0.1, 1)
				local jitter = math.noise(midLX * 0.35, midLZ * 0.35, seed + 700) * 0.03
				local colId = getColorId(terrainColor(midH, nY, biome, maxHeight, jitter))

				local t1 = em:AddTriangle(v1, v2, v3)
				local t2 = em:AddTriangle(v2, v4, v3)
				em:SetFaceColors(t1, { colId, colId, colId })
				em:SetFaceColors(t2, { colId, colId, colId })

				faceCount += 1
				if faceCount % Config.Generation.VertexBudgetPerFrame == 0 then
					shouldYield()
				end
			end
		end
	end

	-- Skirt + bottom ------------------------------------------------------------
	local bottomY = -Config.SkirtDepth
	local bottomIds = {}
	local function bottomVertex(topId: number): number
		local id = bottomIds[topId]
		if not id then
			local p = em:GetPosition(topId)
			id = em:AddVertex(Vector3.new(p.X, bottomY, p.Z))
			bottomIds[topId] = id
		end
		return id
	end

	local rockColId = getColorId(biome.Colors.Rock:Lerp(biome.Colors.Underwater, 0.5))

	-- Boundary = top vertices with fewer than 4 active neighbors. Order them by
	-- angle around the center so consecutive entries trace the perimeter.
	local boundary = {}
	for gz = 0, N - 1 do
		for gx = 0, N - 1 do
			local v = top[gz] and top[gz][gx]
			if v then
				local neighbors = 0
				if top[gz][gx - 1] then
					neighbors = neighbors + 1
				end
				if top[gz][gx + 1] then
					neighbors = neighbors + 1
				end
				if top[gz - 1] and top[gz - 1][gx] then
					neighbors = neighbors + 1
				end
				if top[gz + 1] and top[gz + 1][gx] then
					neighbors = neighbors + 1
				end
				if neighbors < 4 then
					local p = em:GetPosition(v)
					table.insert(boundary, { id = v, ang = math.atan2(p.Z, p.X) })
				end
			end
		end
	end
	table.sort(boundary, function(a, b)
		return a.ang < b.ang
	end)

	local edgeCount = 0
	for i = 1, #boundary do
		local a = boundary[i].id
		local b = boundary[(i % #boundary) + 1].id
		local ba = bottomVertex(a)
		local bb = bottomVertex(b)
		-- Wall quad (two triangles) from the rim down to the skirt floor.
		local w1 = em:AddTriangle(a, ba, bb)
		local w2 = em:AddTriangle(a, bb, b)
		em:SetFaceColors(w1, { rockColId, rockColId, rockColId })
		em:SetFaceColors(w2, { rockColId, rockColId, rockColId })
		edgeCount += 1
		if edgeCount % 64 == 0 then
			shouldYield()
		end
	end

	-- Bottom fan closes the solid.
	local centerBottom = em:AddVertex(Vector3.new(0, bottomY, 0))
	for i = 1, #boundary do
		local a = boundary[i].id
		local b = boundary[(i % #boundary) + 1].id
		local f = em:AddTriangle(centerBottom, bottomVertex(b), bottomVertex(a))
		em:SetFaceColors(f, { rockColId, rockColId, rockColId })
	end

	return em
end

-- EditableMesh -> MeshPart, with fidelity retries ----------------------------

local function meshToPart(em: EditableMesh): MeshPart?
	local attempts = {
		Config.Generation.CollisionFidelity,
		Enum.CollisionFidelity.Default,
	}
	for _, fidelity in attempts do
		local ok, part = pcall(function()
			return AssetService:CreateMeshPartAsync(Content.fromObject(em), {
				CollisionFidelity = fidelity,
				RenderFidelity = Enum.RenderFidelity.Automatic,
			})
		end)
		if ok and part then
			return part
		end
	end
	return nil
end

-- Last-resort fallback terrain: a single round, slightly submerged rock part so
-- a mesh failure still yields a visible, collidable, raycastable island.
local function fallbackTerrainPart(radius: number, biome: any): Part
	local part = Instance.new("Part")
	part.Name = "Terrain"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(Config.SkirtDepth, radius * 2, radius * 2)
	part.Anchored = true
	part.CanCollide = true
	part.Material = Config.Generation.TerrainMaterial
	part.Color = biome.Colors.Rock
	return part
end

-- Island model contract -------------------------------------------------------

-- Creates the "Island" Model ZoneManager expects: a Model with a 1x1x1 anchored
-- Center part (PrimaryPart) and a Radius IntValue.
local function createIslandModel(radius: number): Model
	local model = Instance.new("Model")
	model.Name = "Island"

	local centerPart = Instance.new("Part")
	centerPart.Name = "Center"
	centerPart.Size = Vector3.new(1, 1, 1)
	centerPart.Anchored = true
	centerPart.CanCollide = false
	centerPart.Transparency = 1
	centerPart.Parent = model

	local radiusValue = Instance.new("IntValue")
	radiusValue.Name = "Radius"
	radiusValue.Value = math.round(radius)
	radiusValue.Parent = model

	model.PrimaryPart = centerPart
	model:SetAttribute("GeneratedBy", "IslandGenerator")
	return model
end

-- Radius resolution (contract fallbacks) --------------------------------------

local function readRadius(island: Model): number
	local radiusInst = island:FindFirstChild("Radius")
	if radiusInst and radiusInst:IsA("IntValue") and radiusInst.Value > 0 then
		return radiusInst.Value
	end
	-- Fallback 1: model bounding-box XZ diagonal half (matches ZoneManager).
	local extents = island:GetExtentsSize() * Vector3.new(1, 0, 1)
	local bboxRadius = extents.Magnitude / 2
	if bboxRadius > 1 then
		return bboxRadius
	end
	-- Fallback 2: average of type-category default ranges.
	local sum, n = 0, 0
	for _, def in Config.TypeCategories do
		sum += (def.RadiusMin + def.RadiusMax) / 2
		n += 1
	end
	return n > 0 and sum / n or 70
end

-- Raycast helpers --------------------------------------------------------------

local function raycastDown(pos: Vector3, params: RaycastParams): RaycastResult?
	local start = pos + Vector3.new(0, 60, 0)
	return Workspace:Raycast(start, Vector3.new(0, -260, 0), params)
end

-- True if a boat/player/prop (anything outside Map and Ocean) occupies a spot.
local function hasObstacle(pos: Vector3): boolean
	local hit = raycastDown(pos, obstacleRaycastParams)
	return hit ~= nil
end

-- Part factory -----------------------------------------------------------------

local function makePart(
	name: string,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	cframe: CFrame,
	parent: Instance,
	canCollide: boolean
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = canCollide
	part.CFrame = cframe
	part.Parent = parent
	return part
end

-- Anchored structure builders (procedural, no external assets) -----------------

local function buildShipwreck(def: any, rng: Random): Model
	local model = Instance.new("Model")
	model.Name = "Shipwreck"
	local wood = def.Color
	local dark = def.Color:Lerp(Color3.new(0, 0, 0), 0.35)

	-- Hull: keel, two splayed side planks, a broken bow; hull leans to one side
	-- like a wreck grounded on the seabed.
	local keel = makePart("Keel", Vector3.new(22, 2, 6), wood, def.Material, CFrame.new(0, 0, 0), model, true)
	makePart(
		"HullSide",
		Vector3.new(20, 3, 0.6),
		wood,
		def.Material,
		CFrame.new(0, 1.6, 3) * CFrame.Angles(math.rad(14), 0, 0),
		model,
		true
	)
	makePart(
		"HullSide",
		Vector3.new(20, 3, 0.6),
		wood,
		def.Material,
		CFrame.new(0, 1.6, -3) * CFrame.Angles(math.rad(-14), 0, 0),
		model,
		true
	)
	makePart(
		"BrokenBow",
		Vector3.new(5, 2.5, 5.5),
		wood,
		def.Material,
		CFrame.new(12, 0.6, 0) * CFrame.Angles(0, math.rad(20), 0),
		model,
		true
	)
	-- Fallen mast.
	makePart(
		"Mast",
		Vector3.new(0.8, 16, 0.8),
		dark,
		Enum.Material.Wood,
		CFrame.new(-3, 7, 0) * CFrame.Angles(0, 0, math.rad(68)),
		model,
		true
	)

	model.PrimaryPart = keel
	local list = CFrame.Angles(math.rad(rng:NextNumber(-6, 6)), 0, math.rad(rng:NextNumber(14, 28)))
	model:PivotTo(list)
	return model
end

local function buildRuins(def: any, rng: Random): Model
	local model = Instance.new("Model")
	model.Name = "Ruins"
	local stone = def.Color

	-- Foundation slab + a handful of weathered columns + an optional lintel.
	local slab = makePart("Slab", Vector3.new(16, 1, 14), stone, def.Material, CFrame.new(0, 0, 0), model, true)

	local spots = {
		Vector3.new(-6, 0, -5),
		Vector3.new(6, 0, -5),
		Vector3.new(-6, 0, 5),
		Vector3.new(6, 0, 5),
	}
	local placed = {}
	for i = 1, rng:NextInteger(3, 4) do
		local spot = spots[i]
		local height = rng:NextNumber(5, 9)
		makePart(
			"Column",
			Vector3.new(2, height, 2),
			stone:Lerp(Color3.new(1, 1, 1), 0.05),
			def.Material,
			CFrame.new(spot.X, 0.5 + height / 2, spot.Z)
				* CFrame.Angles(math.rad(rng:NextNumber(-4, 4)), 0, math.rad(rng:NextNumber(-5, 5))),
			model,
			true
		)
		table.insert(placed, { spot = spot, height = height })
	end
	if #placed >= 2 then
		local a, b = placed[1], placed[2]
		local mid = (a.spot + b.spot) / 2
		local len = (a.spot - b.spot).Magnitude + 3
		makePart(
			"Lintel",
			Vector3.new(3, 1.2, len),
			stone,
			def.Material,
			CFrame.new(mid.X, math.max(a.height, b.height) + 0.8, mid.Z)
				* CFrame.Angles(math.rad(rng:NextNumber(-8, 8)), math.rad(90), math.rad(rng:NextNumber(-8, 8))),
			model,
			true
		)
	end

	model.PrimaryPart = slab
	return model
end

local function buildDock(def: any, _rng: Random): Model
	local model = Instance.new("Model")
	model.Name = "Dock"
	local wood = def.Color
	local length = 26

	-- Deck with plank seams; posts drive down toward the seabed; bollards on top.
	makePart("Deck", Vector3.new(length, 1, 7), wood, def.Material, CFrame.new(0, 0, 0), model, true)
	for i = -2, 2 do
		makePart(
			"PlankLine",
			Vector3.new(length - 1, 0.2, 0.4),
			wood:Lerp(Color3.new(0, 0, 0), 0.2),
			def.Material,
			CFrame.new(0, 0.5, i * 1.6),
			model,
			false
		)
	end
	for _, x in { -length / 2 + 2, length / 2 - 2 } do
		for _, z in { -2.6, 2.6 } do
			makePart(
				"Post",
				Vector3.new(1, def.Draft + 2, 1),
				wood:Lerp(Color3.new(0, 0, 0), 0.3),
				Enum.Material.Wood,
				CFrame.new(x, -def.Draft / 2, z),
				model,
				true
			)
		end
	end
	for _, x in { -length / 2 + 3, length / 2 - 3 } do
		makePart(
			"Bollard",
			Vector3.new(1.2, 3, 1.2),
			Color3.fromRGB(40, 40, 40),
			Enum.Material.Metal,
			CFrame.new(x, 1.5, 0),
			model,
			true
		)
	end

	model.PrimaryPart = model:FindFirstChild("Deck")
	return model
end

-- Floating objects -------------------------------------------------------------

local function buildFloatingObject(id: string, def: any): Model
	local model = Instance.new("Model")
	model.Name = id

	local root: Part
	if id == "Barrel" then
		root = Instance.new("Part")
		root.Shape = Enum.PartType.Cylinder
		root.Size = Vector3.new(3, 2.6, 2.6)
		-- Cylinder's circular axis is local X; rotate so X points up => keg.
		root.CFrame = CFrame.Angles(0, 0, math.rad(90))
	elseif id == "Buoy" then
		root = Instance.new("Part")
		root.Shape = Enum.PartType.Ball
		root.Size = Vector3.new(2.4, 2.4, 2.4)
	elseif id == "Debris" then
		root = Instance.new("Part")
		root.Size = Vector3.new(5, 0.6, 1.8)
	else
		root = Instance.new("Part") -- Crate
		root.Size = Vector3.new(2.8, 2.8, 2.8)
	end
	root.Name = "Root"
	root.Color = def.Color
	root.Material = def.Material
	root.Parent = model

	-- 4 sample attachments at the footprint corners, in the exact
	-- TopLeft / TopRight / BottomLeft / BottomRight order BoatManager expects.
	local half = def.Footprint * 0.9
	local offsets = {
		Vector3.new(half, -0.4, half),
		Vector3.new(half, -0.4, -half),
		Vector3.new(-half, -0.4, half),
		Vector3.new(-half, -0.4, -half),
	}
	for i, offset in offsets do
		local att = Instance.new("Attachment")
		att.Name = "Buoyancy" .. i
		att.Position = offset
		att.Parent = root
	end

	model.PrimaryPart = root
	return model
end

-- Floating object motion -------------------------------------------------------

-- Anchored bob (default, stable): every Heartbeat a round-robin slice of the
-- floating objects samples the REAL wave height via BoatManager and gets its
-- Y + pitch/roll updated. X/Z and yaw are preserved so anchored debris can
-- never drift into boats or players.
local function startFloatingHeartbeat()
	if heartbeatConnection then
		return
	end
	heartbeatConnection = RunService.Heartbeat:Connect(function()
		-- Compact out entries whose root was destroyed (e.g. island cleared).
		local writeIdx = 0
		for i = 1, #floatingObjects do
			local entry = floatingObjects[i]
			if entry and entry.root and entry.root.Parent then
				writeIdx += 1
				floatingObjects[writeIdx] = entry
			end
		end
		for i = #floatingObjects, writeIdx + 1, -1 do
			floatingObjects[i] = nil
		end

		local count = #floatingObjects
		if count == 0 then
			return
		end
		if floatingCursor > count then
			floatingCursor = 1
		end
		local perFrame = math.min(Config.Floating.UpdatesPerFrame, count)
		for _ = 1, perFrame do
			local entry = floatingObjects[floatingCursor]
			floatingCursor = (floatingCursor % count) + 1
			if entry and entry.root and entry.root.Parent then
				local root = entry.root
				if root.Anchored then
					local zoneInfo = {
						SpeedMultiplier = 1,
						PhaseMultiplier = 1,
						AmplitudeMultiplier = 1,
						CURRENT_ZONE = nil,
					}
					local bottom = root.Position - Vector3.new(0, root.Size.Y / 2, 0)
					local posDelta, orientation = BoatManager.CalculateBuoyancy(
						root.Position,
						bottom,
						entry.attachments,
						root.Size.X,
						root.Size.Z,
						entry.rideHeight,
						zoneInfo
					)
					if posDelta and posDelta.Y ~= 0 then
						local pitch, _yaw, roll = orientation:ToOrientation()
						local _, yaw, _ = root.CFrame:ToOrientation()
						-- posDelta.Y is an absolute world Y (wave + rideHeight).
						root.CFrame = CFrame.new(root.Position.X, posDelta.Y, root.Position.Z)
							* CFrame.fromEulerAnglesXYZ(pitch, yaw, roll)
					end
				end
			end
		end
	end)
end

-- Optional physical buoyancy (Config.Floating.EnablePhysics = true):
-- unanchored parts ride the waves with a mass-normalized VectorForce spring on
-- Y, a soft XZ leash back to their spawn point, and AlignOrientation matching
-- wave pitch/roll while keeping yaw. Defaults off; anchored bob is preferred.
local function enablePhysicsFor(root: BasePart, attachments: { Attachment }, spawnXZ: Vector3)
	root.Anchored = false
	root.CanCollide = true

	local att0 = Instance.new("Attachment")
	att0.Parent = root

	local align = Instance.new("AlignOrientation")
	align.Attachment0 = att0
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.RigidityEnabled = false
	align.MaxTorque = 40000
	align.Responsiveness = 30
	align.Parent = root

	local force = Instance.new("VectorForce")
	force.Attachment0 = att0
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.Force = Vector3.zero
	force.Parent = root

	local conn
	conn = RunService.Heartbeat:Connect(function()
		if not root or root.Parent == nil then
			conn:Disconnect()
			return
		end
		local zoneInfo = {
			SpeedMultiplier = 1,
			PhaseMultiplier = 1,
			AmplitudeMultiplier = 1,
			CURRENT_ZONE = nil,
		}
		local bottom = root.Position - Vector3.new(0, root.Size.Y / 2, 0)
		local posDelta, orientation = BoatManager.CalculateBuoyancy(
			root.Position,
			bottom,
			attachments,
			root.Size.X,
			root.Size.Z,
			1,
			zoneInfo
		)
		local mass = root.AssemblyMass
		local waveY = posDelta and posDelta.Y or root.Position.Y
		local fY = (waveY - root.Position.Y) * Config.Floating.SpringK
			- root.AssemblyLinearVelocity.Y * Config.Floating.SpringD
		local fX = (spawnXZ.X - root.Position.X) * Config.Floating.LeashK
			- root.AssemblyLinearVelocity.X * Config.Floating.LeashD
		local fZ = (spawnXZ.Z - root.Position.Z) * Config.Floating.LeashK
			- root.AssemblyLinearVelocity.Z * Config.Floating.LeashD
		force.Force = Vector3.new(
			clamp(fX * mass, -Config.Floating.MaxForce, Config.Floating.MaxForce),
			clamp(fY * mass + Workspace.Gravity * mass, -Config.Floating.MaxForce, Config.Floating.MaxForce),
			clamp(fZ * mass, -Config.Floating.MaxForce, Config.Floating.MaxForce)
		)
		local pitch, _yaw, roll = orientation:ToOrientation()
		local _, yaw, _ = root.CFrame:ToOrientation()
		align.CFrame = CFrame.fromEulerAnglesXYZ(pitch, yaw, roll)
	end)
end

-- Structure placement -----------------------------------------------------------

local function isSpotFree(pos: Vector3, footprint: number): boolean
	local pad = Config.Placement.StructuresOverlapPadding
	if #structureTree:SearchRadius(pos, footprint + pad) > 0 then
		return false
	end
	if hasObstacle(pos) then
		return false
	end
	return true
end

-- Spawns one anchored structure. Land ruins raycast onto dry terrain; wreck and
-- dock raycast the shallow seabed at the rim and are deliberately half-submerged.
local function spawnAnchoredStructure(
	defId: string,
	def: any,
	islandModel: Model,
	center: Vector3,
	radius: number,
	rng: Random,
	token: number
): boolean
	local isWater = def.Category == "Water"

	for _ = 1, 8 do
		if generationToken ~= token then
			return false
		end
		local ang = rng:NextNumber(0, math.pi * 2)
		local r = isWater and radius * rng:NextNumber(0.85, 1.05) or radius * rng:NextNumber(0.25, 0.7)
		local pos = Vector3.new(center.X + math.cos(ang) * r, PLANE_Y, center.Z + math.sin(ang) * r)
		local yaw = rng:NextNumber(0, math.pi * 2)

		if not isSpotFree(pos, def.Footprint) then
			continue
		end

		local model: Model?
		if defId == "Shipwreck" then
			local hit = raycastDown(pos, mapRaycastParams)
			if not hit then
				continue
			end
			model = buildShipwreck(def, rng)
			-- Keel rests on / partly in the seabed; the splayed hull and mast
			-- break the surface so the wreck is visible and explorable.
			model:PivotTo(
				CFrame.new(pos.X, hit.Position.Y + 1 + def.Draft * 0.3, pos.Z) * CFrame.Angles(0, yaw, 0)
			)
		elseif defId == "Dock" then
			local hit = raycastDown(pos, mapRaycastParams)
			if not hit then
				continue
			end
			local waterDepth = PLANE_Y - hit.Position.Y
			if waterDepth > def.Draft + 3 or waterDepth < 0.5 then
				continue -- posts must reach the seabed, deck must be over water
			end
			model = buildDock(def, rng)
			model:PivotTo(CFrame.new(pos.X, PLANE_Y + def.AboveWater, pos.Z) * CFrame.Angles(0, yaw, 0))
		else -- Ruins: dry land only.
			local hit = raycastDown(pos, mapRaycastParams)
			if not hit or hit.Position.Y < PLANE_Y + 0.5 then
				continue
			end
			model = buildRuins(def, rng)
			model:PivotTo(
				CFrame.new(pos.X, hit.Position.Y + Config.Placement.StructureGroundEmbed, pos.Z)
					* CFrame.Angles(0, yaw, 0)
			)
		end

		if not model then
			continue
		end
		model:SetAttribute("Structure", defId)
		model.Parent = islandModel
		structureTree:CreateNode(pos, { kind = "anchored", id = defId })
		table.insert(createdInstances, model)
		return true
	end
	return false
end

-- Spawns one floating debris object just beyond the shore in open water.
local function spawnFloatingObject(
	defId: string,
	def: any,
	islandModel: Model,
	center: Vector3,
	radius: number,
	rng: Random,
	token: number
): boolean
	if #floatingObjects >= Config.Placement.MaxFloatingObjectsTotal then
		return false
	end
	for _ = 1, 6 do
		if generationToken ~= token then
			return false
		end
		local ang = rng:NextNumber(0, math.pi * 2)
		local r = radius * rng:NextNumber(1.08, 1.6)
		local pos = Vector3.new(center.X + math.cos(ang) * r, PLANE_Y, center.Z + math.sin(ang) * r)

		-- Reject spots that are still over terrain (object would sit on land).
		local hit = raycastDown(pos, mapRaycastParams)
		if hit and hit.Position.Y > PLANE_Y - 1 then
			continue
		end
		if not isSpotFree(pos, def.Footprint) then
			continue
		end

		local model = buildFloatingObject(defId, def)
		local root = model.PrimaryPart :: Part
		local yaw = rng:NextNumber(0, math.pi * 2)
		local spawnCFrame = CFrame.new(pos.X, PLANE_Y + def.RideHeight, pos.Z) * CFrame.Angles(0, yaw, 0)

		root.Anchored = not Config.Floating.EnablePhysics
		root.CanCollide = Config.Floating.EnablePhysics or Config.Floating.CanCollide
		model:PivotTo(spawnCFrame)
		model:SetAttribute("Floating", defId)
		model.Parent = islandModel

		local attachments = {}
		for i = 1, 4 do
			attachments[i] = root:FindFirstChild("Buoyancy" .. i)
		end

		if Config.Floating.EnablePhysics then
			enablePhysicsFor(root, attachments, Vector3.new(pos.X, 0, pos.Z))
		end

		table.insert(floatingObjects, { root = root, attachments = attachments, rideHeight = def.RideHeight })
		structureTree:CreateNode(pos, { kind = "floating", id = defId })
		table.insert(createdInstances, model)
		return true
	end
	return false
end

-- Core island generation -------------------------------------------------------

-- Builds terrain + structures INTO `islandModel`. The model already has a
-- Center and Radius. `ownsModel` controls cleanup (procedural models are
-- destroyed wholesale; user anchor models are kept and only our content is
-- removed). `registerIsland` adds the center to the island overlap octree.
local function generateIsland(
	islandModel: Model,
	centerPos: Vector3,
	radius: number,
	index: number,
	token: number,
	ownsModel: boolean,
	registerIsland: boolean
)
	local worldSeed = getWorldSeed()
	local rng = Random.new(worldSeed + index)

	-- Pick biome + type from weighted pools.
	local biomePool, typePool = {}, {}
	for name, def in Config.BiomeCategories do
		biomePool[name] = categoryWeight(def)
	end
	for name, def in Config.TypeCategories do
		typePool[name] = categoryWeight(def)
	end
	local biomeName = weightedPickKey(biomePool, rng) or "Jungle"
	local typeName = weightedPickKey(typePool, rng) or "Islet"
	local biome = Config.BiomeCategories[biomeName]
	local typeDef = Config.TypeCategories[typeName]

	local r = math.max(20, radius)

	-- Cheap distance LOD: far islands use a coarser mesh.
	local lodFactor = (Vector3.new(centerPos.X, 0, centerPos.Z).Magnitude > Config.Generation.LOD.Distance)
			and Config.Generation.LOD.ResolutionFactor
		or 1
	local resolution = math.round(((r * 2 * 1.08) / Config.Generation.MeshSpacing) * lodFactor)
	resolution = clamp(resolution, Config.Generation.MinResolution, Config.Generation.MaxResolution)

	-- Yield helper: aborts (throws) if a newer generation started.
	local yield = function()
		if generationToken ~= token then
			error("generation aborted")
		end
		task.wait()
	end

	-- Build the terrain mesh (local space), then place the MeshPart at the
	-- island center. FixedSize = true means part Size == mesh bounds in studs.
	local terrainPart: BasePart?
	local ok, em = pcall(function()
		return buildIslandMesh(r, typeDef.MaxHeight, typeDef.Kind, biome, worldSeed + index * 7, resolution, yield)
	end)
	if ok and em then
		local partOk, part = pcall(meshToPart, em)
		if partOk and part then
			part.Name = "Terrain"
			part.Anchored = true
			part.CanCollide = true
			part.Material = Config.Generation.TerrainMaterial
			part.Color = Color3.new(1, 1, 1) -- vertex colors provide the tint
			part.CFrame = CFrame.new(centerPos.X, PLANE_Y, centerPos.Z)
			part.Parent = islandModel
			terrainPart = part
			table.insert(createdInstances, part)
		end
		pcall(function()
			em:Destroy()
		end)
	end
	if not terrainPart then
		-- Edge case 6: mesh creation failed -> robust solid fallback part.
		local fallback = fallbackTerrainPart(r, biome)
		fallback.CFrame = CFrame.new(centerPos.X, PLANE_Y - Config.SkirtDepth / 2 + 2, centerPos.Z)
			* CFrame.Angles(0, 0, math.rad(90))
		fallback.Parent = islandModel
		terrainPart = fallback
		table.insert(createdInstances, fallback)
	end

	-- Tag + parent so ZoneManager indexes it and depth raycasts include it.
	islandModel:SetAttribute("Biome", biomeName)
	islandModel:SetAttribute("IslandType", typeName)
	CollectionService:AddTag(islandModel, TAG)
	islandModel.Parent = ensureMapFolder()
	if ownsModel then
		table.insert(createdModels, islandModel)
	end
	if registerIsland then
		islandTree:CreateNode(Vector3.new(centerPos.X, PLANE_Y, centerPos.Z), { radius = r })
	end

	-- Structures: weighted picks from the biome's pool, filtered by Mode and
	-- radius fit. Caps keep per-island cost bounded.
	local structPool = biome.Structures or {}
	for _ = 1, Config.Placement.MaxStructuresPerIsland do
		if generationToken ~= token then
			break
		end
		local defId = weightedPickKey(structPool, rng)
		local def = defId and Config.StructureDefinitions[defId]
		if def and def.Mode == "Anchored" and r >= def.MinRadius and r <= def.MaxRadius then
			spawnAnchoredStructure(defId, def, islandModel, centerPos, r, rng, token)
		end
		task.wait()
	end
	for _ = 1, Config.Placement.MaxFloatingObjectsPerIsland do
		if generationToken ~= token then
			break
		end
		local defId = weightedPickKey(structPool, rng)
		local def = defId and Config.StructureDefinitions[defId]
		if def and def.Mode == "Floating" and r >= def.MinRadius and r <= def.MaxRadius then
			spawnFloatingObject(defId, def, islandModel, centerPos, r, rng, token)
		end
		task.wait()
	end

	startFloatingHeartbeat()
end

-- Procedural placement ----------------------------------------------------------

-- Jittered grid with octree overlap rejection; minimum center distance is
-- (rA + rB + SpacingPadding). Deterministic via a dedicated Random stream.
local function generateProceduralAnchors(): { { pos: Vector3, radius: number } }
	local worldSeed = getWorldSeed()
	local rng = Random.new(worldSeed - 101)
	local pl = Config.Placement

	local typePool = {}
	for name, def in Config.TypeCategories do
		typePool[name] = categoryWeight(def)
	end

	local anchors = {}
	local cell = pl.CellSize
	local halfCells = math.ceil(pl.WorldRadius / cell)
	for gx = -halfCells, halfCells do
		for gz = -halfCells, halfCells do
			local x = gx * cell + rng:NextNumber(-cell * pl.GridJitter, cell * pl.GridJitter)
			local z = gz * cell + rng:NextNumber(-cell * pl.GridJitter, cell * pl.GridJitter)
			local distOrigin = math.sqrt(x * x + z * z)
			if distOrigin <= pl.WorldRadius and distOrigin >= pl.SpawnSafetyRadius then
				local typeName = weightedPickKey(typePool, rng) or "Islet"
				local typeDef = Config.TypeCategories[typeName]
				local radius = rng:NextNumber(typeDef.RadiusMin, typeDef.RadiusMax)
				local pos = Vector3.new(x, PLANE_Y, z)

				local ok = true
				for _, node in islandTree:SearchRadius(pos, radius + pl.SpacingPadding + 220) do
					local otherR = node.Object.radius or 0
					if (node.Position - pos).Magnitude < radius + otherR + pl.SpacingPadding then
						ok = false
						break
					end
				end
				if ok then
					islandTree:CreateNode(pos, { radius = radius })
					table.insert(anchors, { pos = pos, radius = radius })
				end
			end
		end
	end
	return anchors
end

-- Public API --------------------------------------------------------------------

-- Generates a brand-new procedural island at a given position.
function IslandGenerator.GenerateOne(centerPos: Vector3, radius: number?, index: number)
	local token = generationToken
	local r = radius
	if not r or r <= 0 then
		local worldSeed = getWorldSeed()
		local rng = Random.new(worldSeed + index)
		local typePool = {}
		for name, def in Config.TypeCategories do
			typePool[name] = categoryWeight(def)
		end
		local typeName = weightedPickKey(typePool, rng) or "Islet"
		local typeDef = Config.TypeCategories[typeName]
		r = rng:NextNumber(typeDef.RadiusMin, typeDef.RadiusMax)
	end
	local model = createIslandModel(r)
	model.PrimaryPart.Position = Vector3.new(centerPos.X, PLANE_Y, centerPos.Z)
	generateIsland(model, centerPos, r, index, token, true, false)
	return model
end

-- Generates content for a user-placed Island model (Center + optional Radius).
-- Returns false if the model was already processed or is invalid.
function IslandGenerator.GenerateForUserIsland(island: Model, index: number): boolean
	if island:GetAttribute("IslandProcessed") then
		return false
	end
	local center = island:FindFirstChild("Center")
	if not center or not center:IsA("BasePart") then
		warn("[IslandGenerator] Island model missing a Center BasePart; skipping.")
		return false
	end
	island:SetAttribute("IslandProcessed", true)

	local radius = readRadius(island)
	if not island:FindFirstChild("Radius") then
		local rv = Instance.new("IntValue")
		rv.Name = "Radius"
		rv.Value = math.round(radius)
		rv.Parent = island
	end
	if not island.PrimaryPart then
		island.PrimaryPart = center
	end

	local pos = center.Position
	center.Anchored = true
	center.CanCollide = false
	if center.Size.Magnitude > math.sqrt(3) + 0.1 then
		center.Size = Vector3.new(1, 1, 1) -- contract: Center is 1x1x1
	end
	-- Keep the Center at the water-plane height so ZoneManager node positions
	-- match procedural islands (X/Z come from wherever the user dropped it).
	center.Position = Vector3.new(pos.X, PLANE_Y, pos.Z)

	local token = generationToken
	island:SetAttribute("GeneratedBy", "IslandGenerator")
	generateIsland(
		island,
		Vector3.new(pos.X, PLANE_Y, pos.Z),
		radius,
		index,
		token,
		false,
		true
	)
	return true
end

-- Full generation pass: user anchors first (sorted for stable indices), then
-- procedural anchors. Batched with task.wait() between islands so a large world
-- never freezes the server.
function IslandGenerator.Generate()
	local token = generationToken + 1
	generationToken = token
	local mapFolder = ensureMapFolder()

	local userIslands = {}
	for _, child in mapFolder:GetChildren() do
		if child:IsA("Model") and child:FindFirstChild("Center") then
			table.insert(userIslands, child)
		end
	end
	table.sort(userIslands, function(a, b)
		local pa = a:FindFirstChild("Center") :: BasePart
		local pb = b:FindFirstChild("Center") :: BasePart
		if math.abs(pa.Position.X - pb.Position.X) > 0.01 then
			return pa.Position.X < pb.Position.X
		end
		return pa.Position.Z < pb.Position.Z
	end)

	local index = 0
	for _, island in userIslands do
		index += 1
		local ok, err = pcall(function()
			IslandGenerator.GenerateForUserIsland(island, index)
		end)
		if not ok and not tostring(err):find("aborted") then
			warn("[IslandGenerator] user island " .. index .. " failed: " .. tostring(err))
		end
		task.wait()
	end

	if Config.Placement.GenerateProcedural then
		for _, anchor in generateProceduralAnchors() do
			if generationToken ~= token then
				break
			end
			index += 1
			local ok, err = pcall(function()
				IslandGenerator.GenerateOne(anchor.pos, anchor.radius, index)
			end)
			if not ok and not tostring(err):find("aborted") then
				warn("[IslandGenerator] island " .. index .. " failed: " .. tostring(err))
			end
			task.wait()
		end
	end

	print("[IslandGenerator] generation complete: " .. index .. " island(s).")
end

-- Removes everything we created. Procedural island models are destroyed whole;
-- content parented into user anchor models is destroyed while the anchor model
-- itself (Center + Radius) is preserved. All internal state resets so a re-run
-- is clean and deterministic (no stale floating objects/octree nodes).
function IslandGenerator.ClearGenerated()
	-- Bump the token so any in-flight generation threads abort themselves.
	generationToken = generationToken + 1
	for _, model in createdModels do
		if model and model.Parent then
			model:Destroy()
		end
	end
	for _, inst in createdInstances do
		if inst and inst.Parent then
			inst:Destroy()
		end
	end
	table.clear(createdModels)
	table.clear(createdInstances)
	table.clear(floatingObjects)
	floatingCursor = 1
	islandTree:ClearAllNodes()
	structureTree:ClearAllNodes()

	local mapFolder = Workspace:FindFirstChild("Map")
	if mapFolder then
		for _, island in mapFolder:GetChildren() do
			if island:IsA("Model") then
				island:SetAttribute("IslandProcessed", nil)
			end
		end
	end
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end

return IslandGenerator
