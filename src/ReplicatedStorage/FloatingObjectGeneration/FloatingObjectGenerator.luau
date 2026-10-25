--!nonstrict
--!optimize 2

--[[
	FloatingObjectGenerator
	=======================
	Server-side streamer for PREMADE, UNANCHORED floating structures/objects.
	Mirrors IslandGenerator: templates are authored as complete Models (or
	single BaseParts) inside ServerStorage.FloatingObjects, discovered
	recursively, and classified by the SIZE TAG on each template:

		"Small" | "Medium" | "Large" | "Debris"      (CollectionService tags)

	Dynamic streaming model ("cache what nobody is looking at"):
		* A deterministic cell record set is created once per world cell, then
		  cached for the server lifetime. Cells are pure data - no instances.
		* A record only becomes a real clone while a player can see it:
		  within its class SimDistance, or inside a player's camera view cone
		  (clients report camera position/look through the CameraReport
		  RemoteEvent; stale/missing reports fall back to distance-only).
		* Physics LOD:
		    - Buoyant: near a player. Unanchored assembly driven by
		      AlignPosition/AlignOrientation toward the Gerstner wave surface
		      through WaveFloat, which applies the ship's own buoyancy model
		      (4 hull-attached surface samples, mean height for the ride,
		      height differences for pitch/roll, proportional drag, an
		      airborne gate). Close objects are refreshed every frame like the
		      ship; the rest ride a staggered clock with softer gains.
		    - Frozen: visible but far. Anchored in place, constraints
		      disabled - zero physics and zero replication cost.
		    - Cached: unseen (or out of range) - the clone is destroyed and
		      only the lightweight record survives. Re-rendering from a
		      record is deterministic and cheap.
		* HARD CAP: at most Config.Streaming.MaxRenderedObjects (500) rendered
		  unanchored objects at once. When the cap is full, objects with NO
		  player nearby are cached first, then the OLDEST rendered objects.

	Placement safety ("never spawns beached/inside things"): a candidate is
	accepted only if it is
		(a) far enough from every other cached floating record (octree),
		(b) outside every island footprint known to ZoneManager's island
		    octree (rendered islands), and
		(c) overlapping no non-ocean BaseParts (boats, docks, baseplate...)
		    via Workspace:GetPartBoundsInRadius. The island generator treats
		    rendered floating objects as obstacles too, so rising islands
		    retry instead of surfacing underneath flotsam.

	References (official docs):
		CollectionService     https://create.roblox.com/docs/reference/engine/classes/CollectionService
		ServerStorage         https://create.roblox.com/docs/reference/engine/classes/ServerStorage
		Instance              https://create.roblox.com/docs/reference/engine/classes/Instance
		Model / PVInstance    https://create.roblox.com/docs/studio/pivot-tools
		AlignPosition         https://create.roblox.com/docs/reference/engine/classes/AlignPosition
		AlignOrientation      https://create.roblox.com/docs/reference/engine/classes/AlignOrientation
		Mover constraints     https://create.roblox.com/docs/physics/mover-constraints
		ForceLimitMode        https://create.roblox.com/docs/reference/engine/enums/ForceLimitMode
		Attachment            https://create.roblox.com/docs/reference/engine/classes/Attachment
		WeldConstraint        https://create.roblox.com/docs/reference/engine/classes/WeldConstraint
		Network ownership     https://create.roblox.com/docs/physics/network-ownership
		Task scheduler        https://create.roblox.com/docs/scripting/scheduler
		WorldRoot bounds      https://create.roblox.com/docs/reference/engine/classes/WorldRoot
		OverlapParams         https://create.roblox.com/docs/reference/engine/datatypes/OverlapParams
		RemoteEvent           https://create.roblox.com/docs/reference/engine/classes/RemoteEvent
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.FloatingObjectConfig)
local WaveFloat = require(script.Parent.WaveFloat)
local Density = require(ReplicatedStorage.IslandGeneration.Density)
local OctreeModule = require(ReplicatedStorage:WaitForChild("Octree"))
local ZoneManager = require(ReplicatedStorage.Gerstner.Serial.ZoneManager)

local PLANE_Y = Config.PlaneOffset
local CONTAINER_FOLDER_NAME = "_FloatingObjects"
local ISLAND_TREE = ZoneManager.ISLAND_TREE

-- Decorrelated from the island generator's cell hash (different multipliers
-- and salt) so floating objects do not line up with island cells.
local HASH_MOD = 2147483647
local HASH_X = 83492791
local HASH_Z = 51719333
local SEED_SALT = 5700427

-- Cull scoring bonus: any Frozen far object always beats a Buoyant far one
-- (removing a frozen object interrupts no simulation).
local FROZEN_CULL_BONUS = 1e9

local FloatingObjectGenerator = {}

-- Forward declarations: defined later, but earlier lifecycle functions
-- (applyBuoyancyTarget, spawnRecord) reference them through these locals.
local cacheObjectRecord
local enforceRenderedLimit

-- Octree of every cached floating record footprint (spacing checks).
local recordOctree = OctreeModule.new()

-- cellCache[key] = { key, cx, cz, records = { record, ... }, lastTouched }
-- or { empty = true, at, lastTouched } marker. nil = not evaluated yet.
local cellCache = {}
local blockedCellRetryAt = {}

-- Rendered/runtime state.
local activeRecords = {} -- [record] = true while its clone is in Workspace
local buoyantRecords = {} -- [record] = true while simulating buoyancy
local recordsByModel = {} -- [Model] = record
local renderedCount = 0

-- Records created by PlaceOne() (not owned by any cell).
local placedRecords = {}

-- Per-player camera interest, fed by FloatingObjectGenerator.SetCameraState.
local cameraStates = {} -- [Player] = { pos: Vector3, look: Vector3, at: number }

-- How many buoyant objects each client is currently simulating, only used when
-- Buoyancy.Ownership = "NearestPlayer" (see setOwnership).
local ownedCountByPlayer = {} -- [Player] = number

-- Catalog / loop state.
local catalog = nil
local seededFromWorkspace = false
local streamingLoopRunning = false
local generationToken = 0
local cachedWorldSeed = nil
local buoyancyConnection: RBXScriptConnection? = nil
local lastTrimAt = 0

-- Lightweight diagnostics counters (exposed through GetStats).
local diagnostics = {
	ActivationAttempts = 0,
	SpawnAttempts = 0,
	SpawnedTotal = 0,
	BlockedSpot = 0,
	CloneFailed = 0,
	CapDeferred = 0,
	CachedTotal = 0,
}

-- OverlapParams for the obstacle broadphase. Ocean, our own container
-- folder, and player characters are excluded. workspace.Map (islands) and
-- _RisingIslands are deliberately KEPT as blockers so nothing generates
-- inside an island that is up or surfacing.
local obstacleParams = OverlapParams.new()
obstacleParams.FilterType = Enum.RaycastFilterType.Exclude
obstacleParams.RespectCanCollide = false
obstacleParams.MaxParts = 8
obstacleParams.FilterDescendantsInstances = {}

-- Config helpers ---------------------------------------------------------------

local function classConfig(className: string)
	local settings = Config.Classes[className]
	if type(settings) ~= "table" then
		settings = {}
	end
	local defaults = Config.DefaultClassSettings or {}
	return {
		Weight = settings.Weight or defaults.Weight or Config.DEFAULT_WEIGHT,
		PerCellMin = settings.PerCellMin or defaults.PerCellMin or 1,
		PerCellMax = math.max(settings.PerCellMax or defaults.PerCellMax or 1, 1),
		ClusterRadius = settings.ClusterRadius or defaults.ClusterRadius or 12,
		MinSpacing = settings.MinSpacing or defaults.MinSpacing or 10,
		SimDistance = settings.SimDistance or defaults.SimDistance or 200,
		FloatRatio = settings.FloatRatio or defaults.FloatRatio or 0.5,
	}
end

local function getStreamingConfig()
	return Config.Streaming or {}
end

local function getBuoyancyConfig()
	return Config.Buoyancy or {}
end

local function getDespawnConfig()
	return Config.Despawn or {}
end

local function isBuoyancyEnabled(): boolean
	local buoyancyConfig = Config.Buoyancy
	return buoyancyConfig == nil or buoyancyConfig.Enabled ~= false
end

local function getViewConeCos(): number
	local streamingConfig = getStreamingConfig()
	local angleDeg = streamingConfig.CameraViewConeAngleDeg or 55
	if angleDeg <= 0 or angleDeg >= 90 then
		return -1 -- everything counts as "in view"
	end
	return math.cos(math.rad(angleDeg))
end

local function getNow(): number
	return Workspace:GetServerTimeNow()
end

-- Small helpers ----------------------------------------------------------------

local function weightedPickIndex(weights: { number }, totalWeight: number, rng: Random): number
	local roll = rng:NextNumber(0, totalWeight)
	local cursor = 0
	for i, weight in weights do
		cursor += weight
		if roll <= cursor then
			return i
		end
	end
	return #weights
end

-- Weighted pick over entries shaped { ..., weight = number }. Falls back to a
-- uniform pick when every weight is <= 0 so generation never breaks.
local function weightedPickEntry(entries: { any }, rng: Random): any
	if #entries == 0 then
		return nil
	end
	local total = 0
	local weights = table.create(#entries)
	for i, entry in entries do
		local weight = entry.weight or Config.DEFAULT_WEIGHT
		if weight <= 0 then
			weight = 0
		end
		weights[i] = weight
		total += weight
	end
	if total <= 0 then
		return entries[rng:NextInteger(1, #entries)]
	end
	return entries[weightedPickIndex(weights, total, rng)]
end

local function getOrCreateFolder(parent: Instance, folderName: string): Folder
	local folder = parent:FindFirstChild(folderName)
	if folder and folder:IsA("Folder") then
		return folder
	end

	local newFolder = Instance.new("Folder")
	newFolder.Name = folderName
	newFolder.Parent = parent
	return newFolder
end

local function ensureContainerFolder(): Folder
	return getOrCreateFolder(Workspace, CONTAINER_FOLDER_NAME)
end

-- Reads the world seed from the SAME IntValue the ocean and island generator
-- use (ReplicatedStorage.Gerstner.Settings.Seed). Settings reseeds a zero
-- value once and persists it, so by require time it is stable. The fixed
-- fallback keeps us deterministic if the IntValue is missing.
local function getWorldSeed(): number
	if cachedWorldSeed ~= nil then
		return cachedWorldSeed
	end

	local seedValue = 7919
	local ok, seedInstance = pcall(function()
		return ReplicatedStorage.Gerstner.Settings:FindFirstChild("Seed")
	end)
	if ok and seedInstance and seedInstance:IsA("IntValue") and seedInstance.Value ~= 0 then
		seedValue = seedInstance.Value
	end
	cachedWorldSeed = seedValue
	return seedValue
end

local function cellKey(cx: number, cz: number): string
	return tostring(cx) .. ":" .. tostring(cz)
end

local function getCellSeed(cx: number, cz: number): number
	local seed = (getWorldSeed() + SEED_SALT + cx * HASH_X + cz * HASH_Z) % HASH_MOD
	if seed < 0 then
		seed += HASH_MOD
	end
	return math.floor(seed)
end

local function refreshObstacleFilters()
	local exclude = {}

	local ocean = Workspace:FindFirstChild("Ocean")
	if ocean then
		table.insert(exclude, ocean)
	end

	local container = Workspace:FindFirstChild(CONTAINER_FOLDER_NAME)
	if container then
		table.insert(exclude, container)
	end

	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end

	obstacleParams.FilterDescendantsInstances = exclude
end

local function hasBlockingObstacle(centerPos: Vector3, radius: number): boolean
	refreshObstacleFilters()
	local parts =
		Workspace:GetPartBoundsInRadius(centerPos, radius + (Config.Placement.ObstaclePadding or 2), obstacleParams)
	return #parts > 0
end

-- Player proximity -------------------------------------------------------------

local function getPlayerRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Closest living player to a world point, and the squared XZ distance to them
-- (nil + math.huge when nobody qualifies). Drives the simulation band, the
-- render-cap culling, and - if configured - network ownership, so it is
-- computed once per decision instead of per question.
local function nearestPlayerInfo(centerPos: Vector3)
	local bestPlayer: Player? = nil
	local best = math.huge
	for _, player in Players:GetPlayers() do
		local root = getPlayerRoot(player)
		if root then
			local dx = root.Position.X - centerPos.X
			local dz = root.Position.Z - centerPos.Z
			local distSq = dx * dx + dz * dz
			if distSq < best then
				best = distSq
				bestPlayer = player
			end
		end
	end
	return bestPlayer, best
end

local function distanceSqToNearestPlayer(centerPos: Vector3): number
	local _, distSq = nearestPlayerInfo(centerPos)
	return distSq
end

-- Distance from one specific player's root to a point. Used to decide whether
-- a prop's current network owner is still close enough to keep it.
local function distanceSqFromPlayer(player: Player, x: number, z: number): number
	local root = getPlayerRoot(player)
	if not root then
		return math.huge
	end
	local dx = root.Position.X - x
	local dz = root.Position.Z - z
	return dx * dx + dz * dz
end

local function getRecordWorldPos(record): Vector3
	if record.hull and record.hull.Parent then
		return record.hull.Position
	end
	return record.centerPos
end

--[[
	Which buoyancy cadence a record rides: the per-frame near band (an object
	gets the ship's own treatment - goals refreshed every simulation step with
	the ship's gains) or the staggered `UpdateInterval` clock.

	The streaming step owns this decision rather than the buoyancy loop: it
	already measured the distance to the nearest player, it runs at a sane
	throttle, and a cadence choice does not need to be re-litigated 60 times a
	second. The exit radius is wider than the entry radius so an object sitting
	on the band edge cannot flip its gains every cycle.
]]
local function updateSimBand(record, nearestSq: number)
	local buoyancyConfig = getBuoyancyConfig()
	local nearDistance = buoyancyConfig.NearDistance or 150
	if nearDistance <= 0 then
		record.nearPlayer = false
		return
	end
	if record.nearPlayer then
		local exitDistance = nearDistance * (buoyancyConfig.NearExitRatio or 1.3)
		if nearestSq > exitDistance * exitDistance then
			record.nearPlayer = false
		end
	else
		record.nearPlayer = nearestSq <= nearDistance * nearDistance
	end
end

-- Camera interest ---------------------------------------------------------------

-- True when at least one client reported a camera recently. When no camera
-- data exists the system degrades to distance-only interest (everything
-- within CacheDistance stays rendered, nothing extra is cached for being
-- "unseen"), which keeps the generator usable without the client script.
local function hasFreshCamera(now: number): boolean
	local timeout = getStreamingConfig().CameraDataTimeout or 3
	for _, state in cameraStates do
		if now - state.at <= timeout then
			return true
		end
	end
	return false
end

-- extraAngleDeg widens the cone (hysteresis): a rendered object keeps its place
-- while it sits at the edge of view instead of flickering out.
local function isSeenByAnyCamera(pos: Vector3, now: number, extraAngleDeg: number?): boolean
	local streamingConfig = getStreamingConfig()
	local timeout = streamingConfig.CameraDataTimeout or 3
	local maxDistance = streamingConfig.CameraMaxDistance or 800
	local viewCos = getViewConeCos()
	if extraAngleDeg and viewCos > -1 then
		local angleDeg = math.min(89, (streamingConfig.CameraViewConeAngleDeg or 55) + extraAngleDeg)
		viewCos = math.cos(math.rad(angleDeg))
	end

	for _, state in cameraStates do
		if now - state.at <= timeout then
			local offset = pos - state.pos
			local dist = offset.Magnitude
			if dist <= maxDistance then
				if dist < 8 then
					return true -- effectively on top of the camera
				end
				if state.look:Dot(offset / dist) >= viewCos then
					return true
				end
			end
		end
	end
	return false
end

-- Catalog / discovery ----------------------------------------------------------

-- Returns the class name for a template instance by reading its size tags in
-- Config.ClassTags priority order. nil = untagged (skipped with a warning).
local function classifyTemplate(instance: Instance): string?
	for _, mapping in Config.ClassTags do
		if CollectionService:HasTag(instance, mapping.Tag) then
			return mapping.Class
		end
	end
	return nil
end

-- Collects template candidates under `folder`, recursing through nested
-- folders of any depth. Like the island generator, we do NOT descend into
-- Models: a model's children are object components (a mast, a crate stack),
-- not separate templates.
local function collectTemplates(folder: Instance, out)
	for _, child in folder:GetChildren() do
		if child:IsA("Model") or child:IsA("BasePart") then
			table.insert(out, child)
		elseif child:IsA("Folder") then
			collectTemplates(child, out)
		end
	end
end

local function templateExtentXZ(instance: Instance): number
	if instance:IsA("BasePart") then
		local size = instance.Size
		return math.max(size.X, size.Z)
	elseif instance:IsA("Model") then
		local extents = instance:GetExtentsSize()
		return math.max(extents.X, extents.Z)
	end
	return 0
end

-- Builds the class catalog from ServerStorage.<TemplatesRoot>.
--   * Every tagged Model/BasePart under the root (any folder depth) joins the
--     pool of its tag's class.
--   * A template's optional "Weight" attribute overrides its rarity weight.
--   * Untagged / part-less templates are skipped and warned about ONCE.
local function buildCatalog()
	local root = ServerStorage:FindFirstChild(Config.TemplatesRoot)
	catalog = {}
	if not root then
		return catalog
	end

	local candidates = {}
	collectTemplates(root, candidates)

	local skipped = {}
	for _, instance in candidates do
		local className = classifyTemplate(instance)
		if not className then
			table.insert(skipped, instance:GetFullName())
			continue
		end

		if instance:IsA("Model") and not instance:FindFirstChildWhichIsA("BasePart", true) then
			table.insert(skipped, instance:GetFullName() .. " (no BasePart)")
			continue
		end

		local weight = Config.DEFAULT_WEIGHT
		local attributeWeight = instance:GetAttribute("Weight")
		if typeof(attributeWeight) == "number" and attributeWeight > 0 then
			weight = attributeWeight
		end

		local entry = catalog[className]
		if not entry then
			entry = {
				name = className,
				weight = classConfig(className).Weight,
				templates = {},
			}
			catalog[className] = entry
		end
		table.insert(entry.templates, {
			instance = instance,
			weight = weight,
			extentXZ = templateExtentXZ(instance),
		})
	end

	if #skipped > 0 then
		warn(
			"[FloatingObjectGenerator] skipped "
				.. #skipped
				.. " untagged/empty template(s) under ServerStorage."
				.. Config.TemplatesRoot
				.. " (expected tags: "
				.. table.concat(
					(function()
						local names = {}
						for _, mapping in Config.ClassTags do
							table.insert(names, mapping.Tag)
						end
						return names
					end)(),
					", "
				)
				.. "): "
				.. table.concat(skipped, ", ")
		)
	end

	return catalog
end

-- Returns the usable class entries. If the last discovery attempt found
-- nothing (missing root, templates not yet added), retries on a short
-- throttle so a late-created ServerStorage folder starts working without a
-- restart while empty-root scans stay cheap.
local lastCatalogAttemptAt = -math.huge
local function getCatalogList(): { any }
	local function flatten()
		local list = {}
		if catalog ~= nil then
			for _, entry in catalog do
				if entry.weight > 0 and #entry.templates > 0 then
					table.insert(list, entry)
				end
			end
		end
		return list
	end

	local list = flatten()
	if #list > 0 then
		return list
	end

	local now = getNow()
	if now - lastCatalogAttemptAt > 2 then
		lastCatalogAttemptAt = now
		buildCatalog()
		list = flatten()
	end
	return list
end

-- Placement validation ---------------------------------------------------------

-- True if `centerPos` is a safe spot for a floating object with footprint
-- `spacingRadius`. Checks (a) other cached floating records, (b) island
-- footprints known to ZoneManager, and optionally (c) workspace obstacles.
-- Pass `ignoredRecord` when re-validating a record whose own footprint node
-- is already in the octree (e.g. at spawn time).
local function isSpotClear(
	centerPos: Vector3,
	spacingRadius: number,
	checkObstacles: boolean?,
	ignoredRecord: any?
): boolean
	local pl = Config.Placement

	-- (a) Floating record spacing via our octree.
	local searchRadius = spacingRadius + (pl.MaxSpacingRadius or 48)
	for _, node in recordOctree:SearchRadius(centerPos, searchRadius) do
		local object = node.Object or {}
		if object.record ~= ignoredRecord then
			local otherSpacing = object.spacingRadius or 10
			if (node.Position - centerPos).Magnitude < spacingRadius + otherSpacing then
				return false
			end
		end
	end

	-- (b) Island footprints via ZoneManager's island octree. Nodes are
	-- { Island = Model, Radius = number } at the island Center position.
	local islandSearch = spacingRadius + (pl.IslandAvoidPadding or 24) + (pl.MaxIslandRadius or 400)
	for _, node in ISLAND_TREE:SearchRadius(centerPos, islandSearch) do
		local object = node.Object or {}
		local islandRadius = object.Radius or 0
		if (node.Position - centerPos).Magnitude < spacingRadius + islandRadius + (pl.IslandAvoidPadding or 24) then
			return false
		end
	end

	-- (c) Obstacles via broadphase sphere query.
	if checkObstacles ~= false and hasBlockingObstacle(centerPos, spacingRadius) then
		return false
	end

	return true
end

-- Buoyancy helpers ---------------------------------------------------------------

-- Heading (radians about Y) of a hull's current facing, flattened to XZ.
local function currentYaw(hull: BasePart): number
	local look = hull.CFrame.LookVector
	local x, z = look.X, look.Z
	if x * x + z * z < 0.0025 then
		return 0 -- looking straight up/down; keep the last upright frame
	end
	return math.atan2(-x, -z)
end

-- Re-reads ZoneManager wave multipliers for an object (islands/whirlpools
-- damp waves). Mirrors the ship singleton's client update logic, but at a
-- low per-object cadence because GetZoneParameters walks the zone octrees.
local function refreshZone(record, now: number)
	local sim = record.sim
	local hull = record.hull
	if not sim or not hull or not hull.Parent then
		return
	end

	local zone = ZoneManager:GetZoneParameters(hull.Position)
	if zone and zone.Type ~= "Whirlpool" then
		if zone.Link then
			sim.zone.PhaseMultiplier, sim.zone.SpeedMultiplier, sim.zone.AmplitudeMultiplier =
				ZoneManager:GetZoneMultipliers(hull.Position, zone.Link.Position, zone)
		elseif zone.Island then
			local center = zone.Island:FindFirstChild("Center")
			if center and center:IsA("BasePart") then
				sim.zone.PhaseMultiplier, sim.zone.SpeedMultiplier, sim.zone.AmplitudeMultiplier =
					ZoneManager:GetIslandMultipliers(hull.Position, center.Position, (zone.Radius or 0) / 2)
			end
		end
		sim.zone.CURRENT_ZONE = zone
	else
		sim.zone.PhaseMultiplier = 1
		sim.zone.SpeedMultiplier = 1
		sim.zone.AmplitudeMultiplier = 1
		sim.zone.CURRENT_ZONE = zone
	end
	sim.nextZoneAt = now + (getBuoyancyConfig().ZoneRefreshInterval or 3)
end

--[[
	Refreshes one buoyant object's AlignPosition / AlignOrientation goals.

	`near` picks the cadence class, decided by the streaming step (it knows how
	far the closest player is) and used here:

		* near  -> refreshed every frame with the ship's own gains, i.e. exactly
		  what `Ship.Client` does in its PostSimulation callback;
		* not   -> refreshed on the staggered `UpdateInterval` clock, and with
		  the SOFT gains, so a goal that only moves 8 times a second arrives as
		  a glide rather than a staircase.

	The soft gains are also used whenever the object is far off its goal - just
	unfrozen from the LOD band, just splashed back down, or just kicked by a
	player - which is what stops a prop teleporting onto the waterline.
]]
local function applyBuoyancyTarget(record, now: number, near: boolean, buoyancyConfig)
	local sim = record.sim
	local hull = record.hull
	if not sim or not hull or not hull.Parent then
		return
	end

	local interval = near and (buoyancyConfig.NearUpdateInterval or 0) or (buoyancyConfig.UpdateInterval or 0.12)
	sim.nextUpdateAt = now + interval

	-- Physics escape hatch: an object squeezed far below the water plane is
	-- gone for good; reclaim its render slot.
	if hull.Position.Y < PLANE_Y - (buoyancyConfig.KillDepth or 160) then
		cacheObjectRecord(record, "Lost", true)
		return
	end

	if now >= (sim.nextZoneAt or 0) then
		refreshZone(record, now)
	end

	-- The ship's buoyancy model, sampled at this object's own hull attachments
	-- (see WaveFloat). `waterline` is the depth reference and `slopeX/slopeZ`
	-- are the distances the corner samples actually sit at.
	local targetY, orientation, depth, failed = WaveFloat.Solve(
		sim.points,
		hull.AssemblyCenterOfMass.Y,
		sim.waterline.WorldPosition.Y,
		sim.slopeZ,
		sim.slopeX,
		sim.heightParam,
		sim.zone,
		buoyancyConfig.HeightSource or "ANALYTIC",
		buoyancyConfig.LookupMethod or "PRECISE",
		now
	)

	if failed then
		-- A MESH lookup could not resolve the surface (no triangle under the
		-- point). Keep the previous goal and retry shortly rather than
		-- disabling the sim, which would drop the object through the water.
		sim.nextUpdateAt = now + 0.25
		return
	end

	-- Heading. Commanded, not copied raw off the bobbing hull - see
	-- WaveFloat.AdvanceYaw.
	local yaw = WaveFloat.AdvanceYaw(
		sim.yaw,
		currentYaw(hull),
		math.rad(buoyancyConfig.YawDeadbandDegrees or 5),
		buoyancyConfig.YawSmoothing or 0.25
	)
	sim.yaw = yaw
	local goal = CFrame.fromEulerAnglesXYZ(0, yaw, 0) * orientation

	-- "Far off the goal" is measured the way the constraint sees it: the height
	-- error at the mover attachment, and the angle between the hull's up axis
	-- and the goal's.
	local errorY = 0
	local signedError = 0
	if targetY ~= nil then
		signedError = targetY - sim.mover.WorldPosition.Y
		errorY = math.abs(signedError)
	end

	-- Integral action (Small and Medium only, IntegralClasses). The servo's goal
	-- leads the object by about a stud at steady state, so the object rides low
	-- (floating/NOTES.md). While the object is riding (near, and within
	-- SettleDistance of its nominal height), the goal is biased by the integral of
	-- its height error, which drives that error toward zero. The bias is clamped,
	-- and it is frozen when the object is not riding.
	local goalY = targetY
	if targetY ~= nil and sim.integralGain > 0 then
		local dt = math.min(now - (sim.integralAt or now), 0.25)
		sim.integralAt = now
		if near and errorY <= (buoyancyConfig.SettleDistance or 2) then
			local maxBias = buoyancyConfig.IntegralMaxBias or 1.5
			sim.integralBias = math.clamp(sim.integralBias + sim.integralGain * signedError * dt, -maxBias, maxBias)
		end
		goalY = targetY + sim.integralBias
	end
	local settleCos = math.cos(math.rad(buoyancyConfig.SettleAngleDegrees or 15))
	local soft = not near
		or errorY > (buoyancyConfig.SettleDistance or 2)
		or goal.UpVector:Dot(hull.CFrame.UpVector) < settleCos

	-- Attitude is commanded even while the object is in the air - the ship keeps
	-- writing its orientation through its airborne window too - so a prop lands
	-- matching the wave it is about to hit instead of in whatever pose it left
	-- the crest in.
	local alignOrientation = sim.alignOrientation
	alignOrientation.CFrame = goal
	if soft then
		alignOrientation.MaxTorque = sim.mass * (buoyancyConfig.SoftTorqueMultiplier or 1200)
		alignOrientation.MaxAngularVelocity = buoyancyConfig.SoftMaxAngularVelocity or 3
		alignOrientation.Responsiveness = buoyancyConfig.SoftAngularResponsiveness or 8
	else
		alignOrientation.MaxTorque = sim.torqueBase
		alignOrientation.MaxAngularVelocity = buoyancyConfig.MaxAngularVelocity or 8
		alignOrientation.Responsiveness = buoyancyConfig.AngularResponsiveness or 12
	end

	local alignPosition = sim.alignPosition
	if targetY == nil then
		-- WaveFloat says the bottom of the hull is clear of the water: stop
		-- driving it and let gravity bring it back down, which is the ship's
		-- `alignPosition.Enabled = false` during its airborne window.
		alignPosition.Enabled = false
		return
	end

	if soft then
		alignPosition.MaxVelocity = buoyancyConfig.SoftMaxVelocity or 14
		alignPosition.Responsiveness = buoyancyConfig.SoftResponsiveness or 8
	else
		alignPosition.MaxVelocity = buoyancyConfig.MaxVelocity or 80
		alignPosition.Responsiveness = buoyancyConfig.Responsiveness or 12
	end

	local driveY = sim.maxForceBase * (1 + depth / 10)
	if sim.verticalOnly then
		-- PerAxis limits: the servo can only push along Y, so nothing in
		-- the goal's X/Z can pull the object sideways. `DriftReturnForce`
		-- buys back a little horizontal authority so a kicked prop slowly
		-- returns to its patch of ocean instead of sailing off.
		local drift = driveY * (buoyancyConfig.DriftReturnForce or 0)
		alignPosition.MaxAxesForce = Vector3.new(drift, driveY, drift)
	else
		alignPosition.MaxForce = driveY
	end

	-- In OneAttachment mode `Position` is a WORLD goal, so the X/Z we write
	-- is where the attachment is driven to: the object's own spawn column
	-- when drift-return is armed, otherwise its current column (zero
	-- horizontal error -> the servo only ever corrects height).
	local attachPos = sim.mover.WorldPosition
	local goalX, goalZ = attachPos.X, attachPos.Z
	if (buoyancyConfig.DriftReturnForce or 0) > 0 then
		goalX, goalZ = sim.homeX, sim.homeZ
	end
	alignPosition.Position = Vector3.new(goalX, goalY, goalZ)
	alignPosition.Enabled = true
end

-- Record/model lifecycle ---------------------------------------------------------

local function markRendered(record)
	if record.rendered then
		return
	end
	record.rendered = true
	renderedCount += 1
	activeRecords[record] = true
end

local function unmarkRendered(record)
	if not record.rendered then
		return
	end
	record.rendered = false
	renderedCount = math.max(0, renderedCount - 1)
	activeRecords[record] = nil
	if buoyantRecords[record] then
		buoyantRecords[record] = nil
	end
end

--[[
	Network ownership for one rendered object.

	"Server" (the default) keeps physics authoritative here: deterministic, and
	an exploiter cannot fling a prop at a player. The price is that a player who
	pushes a prop does it through a round trip.

	"NearestPlayer" is what makes the SHIP feel right, applied to props: the
	client closest to an assembly simulates it at 60 fps, so the player looking
	at a prop sees it move in perfect lockstep with the water they are simulating
	locally. `AlignPosition.Position`/`MaxAxesForce` are still written by the
	server - only the simulation moves - so the wave field stays a single source
	of truth.

	Ownership is only ever changed from the streaming step (never per frame), is
	limited to objects inside `OwnDistance`, is capped per player, and is sticky
	inside `OwnDistance * OwnKeepRatio`, so walking around does not make whole
	clusters of props hop between clients.
]]
local function setOwnership(record, canOwn: boolean?)
	local parts = record.parts
	if not parts then
		return
	end

	local buoyancyConfig = getBuoyancyConfig()
	local want: Player? = nil

	if canOwn ~= false and buoyancyConfig.Ownership == "NearestPlayer" then
		local ownDistance = buoyancyConfig.OwnDistance or 150
		local maxOwned = buoyancyConfig.MaxOwnedPerPlayer or 64
		local pos = getRecordWorldPos(record)
		local nearest, nearestSq = record.nearestPlayer, record.nearestSq
		if not nearestSq then
			nearest, nearestSq = nearestPlayerInfo(pos)
		end

		if nearest and nearestSq <= ownDistance * ownDistance then
			want = nearest
			-- Prefer the current owner while it is still close: handing an
			-- assembly between peers costs a physics handoff, and the previous
			-- owner then sees its own prop stutter.
			local current = record.owner
			if current and current ~= nearest then
				local keepDistance = ownDistance * (buoyancyConfig.OwnKeepRatio or 1.6)
				if distanceSqFromPlayer(current, pos.X, pos.Z) <= keepDistance * keepDistance then
					want = current
				end
			end
			if want ~= record.owner and (ownedCountByPlayer[want] or 0) >= maxOwned then
				want = nil -- that player is already simulating enough props
			end
		end
	end

	local current = record.owner
	if current == want then
		return
	end
	if current then
		ownedCountByPlayer[current] = math.max(0, (ownedCountByPlayer[current] or 1) - 1)
	end
	if want then
		ownedCountByPlayer[want] = (ownedCountByPlayer[want] or 0) + 1
	end
	record.owner = want

	for _, part in parts do
		if part.Parent and part:IsA("BasePart") and not part.Anchored then
			local ok, canSet = pcall(function()
				return part:CanSetNetworkOwnership()
			end)
			if ok and canSet then
				part:SetNetworkOwner(want)
			end
		end
	end
end

-- Drops the per-player bookkeeping for a record that no longer needs an owner
-- (cached, despawned, or its owner left). The parts go away with the clone, so
-- there is no ownership to hand back - only the tally.
local function forgetOwnership(record)
	local owner = record.owner
	if owner then
		record.owner = nil
		local count = ownedCountByPlayer[owner]
		if count and count > 1 then
			ownedCountByPlayer[owner] = count - 1
		else
			ownedCountByPlayer[owner] = nil
		end
	end
end

-- Total number of rendered props clients are simulating for us. Exposed in
-- GetStats so a server under load can see the ownership mode doing its job.
local function clientOwnedCount(): number
	local total = 0
	for _, count in ownedCountByPlayer do
		total += count
	end
	return total
end

-- Anchors/unanchors the whole assembly and toggles its constraints.
-- Frozen = zero physics cost and no replication (a static anchored prop).
local function setObjectFrozen(record, frozen: boolean)
	local model = record.model
	local parts = record.parts
	if not model or not parts then
		return
	end

	local sim = record.sim
	if sim then
		sim.alignPosition.Enabled = not frozen and isBuoyancyEnabled()
		sim.alignOrientation.Enabled = not frozen and isBuoyancyEnabled()
	end

	if frozen then
		-- Hand the assembly back to the server BEFORE it is anchored: an
		-- anchored part cannot hold a network owner, and taking a client-owned
		-- prop away mid-simulation is how parts end up desynced between peers.
		setOwnership(record, false)
	end

	for _, part in parts do
		if part.Parent then
			part.Anchored = frozen
		end
	end

	record.state = frozen and "Frozen" or "Buoyant"
	model:SetAttribute("FloatingState", record.state)

	if not frozen then
		local hull = record.hull
		if hull and hull.Parent then
			hull.AssemblyLinearVelocity = Vector3.zero
			hull.AssemblyAngularVelocity = Vector3.zero
		end
		if sim then
			-- Resume from the pose the object is actually in (a frozen prop kept
			-- its heading, but the water under it moved on), refresh next frame,
			-- and stay on the soft gains so it eases onto the surface instead of
			-- snapping to it from wherever it froze.
			sim.yaw = currentYaw(hull)
			sim.nextUpdateAt = 0
			buoyantRecords[record] = true
		end
		setOwnership(record, true)
	elseif sim then
		buoyantRecords[record] = nil
	end
end

local function disconnectRecordSignals(record)
	local connection = record.destroyingConnection
	if connection then
		record.destroyingConnection = nil
		connection:Disconnect()
	end
end

-- Diagnostics: how many times each cache reason fired this session.
local cacheCounts = {}

-- Destroys the clone and returns the record to the lightweight cache, or
-- permanently despawns it (`permanent`, e.g. lifetime expiry / physics loss).
function cacheObjectRecord(record, reason: string, permanent: boolean?)
	cacheCounts[reason] = (cacheCounts[reason] or 0) + 1
	disconnectRecordSignals(record)
	forgetOwnership(record)
	record.nearestPlayer = nil
	record.nearestSq = nil

	local model = record.model
	if model then
		recordsByModel[model] = nil
		if model.Parent then
			model:Destroy()
		end
	end

	record.model = nil
	record.hull = nil
	record.parts = nil
	record.sim = nil
	record.unseenSince = nil
	record.activatedAt = nil
	record.expiresAt = nil
	unmarkRendered(record)

	if permanent then
		record.state = "Despawned"
		record.dead = true
		record.despawnedAt = getNow()
		if record.node then
			recordOctree:RemoveNode(record.node)
			record.node = nil
		end
	else
		record.state = "Cached"
		record.cacheReason = reason
		local cooldown
		if reason == "RenderLimit" then
			cooldown = getDespawnConfig().CullCooldown or 30
		else
			cooldown = getStreamingConfig().RespawnCooldown or 1.5
		end
		record.respawnCooldownUntil = getNow() + cooldown
	end
end

-- Finds the biggest BasePart (by volume) to use as the physics hull, unless
-- the template set a PrimaryPart.
local function pickHull(model: Model): BasePart?
	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
		return model.PrimaryPart
	end

	local best: BasePart? = nil
	local bestVolume = -1
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local size = descendant.Size
			local volume = size.X * size.Y * size.Z
			if volume > bestVolume then
				bestVolume = volume
				best = descendant
			end
		end
	end
	return best
end

-- Clones + prepares the assembly for a record. Returns the model, or nil if
-- the template became unusable.
local function buildClone(record): Model?
	local template = record.template
	if not template or not template.Parent then
		return nil
	end

	local clone: Model
	if template:IsA("Model") then
		local model = template:Clone() :: Model
		if not model:FindFirstChildWhichIsA("BasePart", true) then
			return nil
		end
		clone = model
	else
		local wrapped = Instance.new("Model")
		wrapped.Name = template.Name
		local part = template:Clone()
		part.Parent = wrapped
		wrapped.PrimaryPart = part :: BasePart
		clone = wrapped
	end

	local hull = pickHull(clone)
	if not hull then
		clone:Destroy()
		return nil
	end
	clone.PrimaryPart = hull
	hull.RootPriority = 100 -- keep the hull as the assembly root

	-- Unanchor everything: these are UNANCHORED floating objects. Anchored
	-- parts inside an assembly would freeze the whole thing.
	local parts = {}
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			table.insert(parts, descendant)
		end
	end

	-- Weld every part to the hull so the object rides as ONE assembly even
	-- when the author did not add welds. Extra WeldConstraints alongside
	-- author welds are harmless.
	if #parts > 1 then
		for _, part in parts do
			if part ~= hull then
				local weld = Instance.new("WeldConstraint")
				weld.Name = "FloatingAssemblyWeld"
				weld.Part0 = hull
				weld.Part1 = part
				weld.Parent = hull
			end
		end
	end

	-- Remove constraints that would fight the buoyancy sim, plus any legacy
	-- (deprecated) BodyMovers left in the authored asset.
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("AlignPosition") or descendant:IsA("AlignOrientation") or descendant:IsA("BodyMover") then
			descendant:Destroy()
		end
	end

	return clone
end

-- Builds the buoyancy rig: the mover + waterline attachments, the four surface
-- sample attachments, and the AlignPosition/AlignOrientation pair that drives
-- them - deliberately the same rig shape the ship singleton builds for itself
-- in `Ship.Client`. Called once the clone is parented, so mass and world
-- transforms are readable.
local function buildSim(record)
	local model = record.model
	local hull = record.hull
	if not model or not hull then
		return
	end

	local buoyancyConfig = getBuoyancyConfig()
	local bboxCFrame, bboxSize = model:GetBoundingBox()
	local inset = buoyancyConfig.SampleInset or 0.9
	local halfWidth = (bboxSize.X * inset) / 2
	local halfLength = (bboxSize.Z * inset) / 2

	-- A 3-stud crate 3 studs wide divides a sub-stud height difference by 3 and
	-- concludes the sea is flat - and with the MESH source both corners can
	-- land inside one ocean triangle, which says exactly the same thing.
	-- Widening the sample baseline to at least `SlopeBaselineStuds` is what
	-- lets a small prop read a meaningful slope and tilt with the swell.
	local baseline = math.max(buoyancyConfig.SlopeBaselineStuds or 8, 2)
	if halfWidth * 2 < baseline then
		halfWidth = baseline / 2
	end
	if halfLength * 2 < baseline then
		halfLength = baseline / 2
	end

	-- Fraction of the object's height riding ABOVE the waterline.
	local floatRatio = record.floatRatio or 0.5
	local heightParam = bboxSize.Y * (floatRatio - 0.5)

	local mover = Instance.new("Attachment")
	mover.Name = "FloatingMover"
	mover.CFrame = hull.CFrame:ToObjectSpace(bboxCFrame)
	mover.Parent = hull

	-- Depth reference = the hull's bottom, mirroring the ship's `Main.Center`
	-- attachment. It must NOT be the bounding-box centre: for a tall template
	-- (wreck with a mast, dock with a cabin) the centre sits far above the
	-- water, the airborne gate then reads "clear air under the keel", switches
	-- the servo off, and the object free-falls out of the ocean until the
	-- kill-depth reaper despawns it.
	local waterline = Instance.new("Attachment")
	waterline.Name = "FloatingWaterline"
	waterline.CFrame = hull.CFrame:ToObjectSpace(bboxCFrame * CFrame.new(0, -bboxSize.Y / 2, 0))
	waterline.Parent = hull

	local mass = math.max(hull.AssemblyMass, 0.1)
	local forceBase = mass * Workspace.Gravity * (buoyancyConfig.ForceMultiplier or 4)
	local verticalOnly = buoyancyConfig.VerticalOnlyForce ~= false

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "FloatingBuoyancy"
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = mover
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.RigidityEnabled = false
	if verticalOnly then
		-- PerAxis caps each axis on its own, so buoyancy can only exist along
		-- Y: the servo cannot drag a prop sideways out of a wave, and it stops
		-- damping the horizontal shove a player gives it. In Magnitude mode
		-- `MaxForce` caps the TOTAL force, so any X/Z error in the goal eats
		-- the budget that should be lifting the hull.
		alignPosition.ForceLimitMode = Enum.ForceLimitMode.PerAxis
		alignPosition.ForceRelativeTo = Enum.ActuatorRelativeTo.World
		alignPosition.MaxAxesForce = Vector3.new(0, forceBase, 0)
	else
		alignPosition.MaxForce = forceBase
	end
	-- Start on the soft gains: a freshly rendered prop glides onto the surface
	-- instead of snapping to it. `applyBuoyancyTarget` promotes them once it is
	-- actually riding the wave.
	alignPosition.MaxVelocity = buoyancyConfig.SoftMaxVelocity or 14
	alignPosition.Responsiveness = buoyancyConfig.SoftResponsiveness or 8
	-- Seed the goal with the attachment's own position: `Enabled` is false, but
	-- an object that freezes again before its first refresh must not inherit a
	-- stale goal, and one frame of physics runs before the loop writes a target.
	alignPosition.Position = mover.WorldPosition
	alignPosition.Enabled = false
	alignPosition.Parent = hull

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "FloatingWaveOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = mover
	alignOrientation.MaxTorque = mass * (buoyancyConfig.SoftTorqueMultiplier or 1200)
	alignOrientation.MaxAngularVelocity = buoyancyConfig.SoftMaxAngularVelocity or 3
	alignOrientation.Responsiveness = buoyancyConfig.SoftAngularResponsiveness or 8
	alignOrientation.RigidityEnabled = false
	alignOrientation.Enabled = false
	alignOrientation.Parent = hull

	-- Four hull-attached samples, ordered like BoatManager expects so the rig
	-- reads the same as the ship's `Main` attachments: front = -Z, right = +X.
	local function cornerAttachment(name: string, sx: number, sz: number): Attachment
		local attachment = Instance.new("Attachment")
		attachment.Name = name
		local corner = bboxCFrame * CFrame.new(sx * halfWidth, 0, sz * halfLength)
		attachment.CFrame = hull.CFrame:ToObjectSpace(corner)
		attachment.Parent = hull
		return attachment
	end

	local moverWorld = mover.WorldPosition
	-- Integral action on the buoyancy goal, Small and Medium only (see applyBuoyancyTarget).
	local buoyancyCfg = getBuoyancyConfig()
	local integralClasses = buoyancyCfg.IntegralClasses or {}
	record.sim = {
		mover = mover,
		waterline = waterline,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		points = {
			cornerAttachment("FloatTopLeft", -1, -1), -- front-left
			cornerAttachment("FloatTopRight", 1, -1), -- front-right
			cornerAttachment("FloatBottomLeft", -1, 1), -- back-left
			cornerAttachment("FloatBottomRight", 1, 1), -- back-right
		},
		-- The distances the samples actually sit AT: the solver divides the
		-- height differences by these to get the slope, so they must match the
		-- (possibly widened) rig geometry, not the raw bounding box.
		slopeX = halfWidth * 2,
		slopeZ = halfLength * 2,
		heightParam = heightParam,
		mass = mass,
		maxForceBase = forceBase,
		torqueBase = mass * (buoyancyConfig.TorqueMultiplier or 5000),
		verticalOnly = verticalOnly,
		homeX = moverWorld.X,
		homeZ = moverWorld.Z,
		integralGain = integralClasses[record.className] and (buoyancyCfg.IntegralGain or 0) or 0,
		integralBias = 0,
		integralAt = nil,
		yaw = record.yaw or 0,
		nextUpdateAt = 0,
		nextZoneAt = 0,
		zone = {
			SpeedMultiplier = 1,
			PhaseMultiplier = 1,
			AmplitudeMultiplier = 1,
			CURRENT_ZONE = nil,
		},
	}
end

-- Spawns (renders) a cached record: clones the template, welds/unanchors the
-- assembly, seats it on the WAVE it is supposed to be floating on (not the
-- flat mean waterline - a prop that pops in a stud under the surface starts
-- its life being dragged up, which reads as a hitch), rigs its buoyancy
-- attachments, and starts it in Buoyant or Frozen state.
local function spawnRecord(record, wantFrozen: boolean?): Model?
	if record.dead or record.rendered then
		return record.model
	end

	local streamingConfig = getStreamingConfig()
	local now = getNow()
	if record.respawnCooldownUntil and now < record.respawnCooldownUntil then
		return nil
	end
	if record.blockedUntil and now < record.blockedUntil then
		return nil
	end
	diagnostics.SpawnAttempts += 1

	local maxRendered = streamingConfig.MaxRenderedObjects or 500
	if renderedCount >= maxRendered then
		enforceRenderedLimit(1)
		if renderedCount >= maxRendered then
			diagnostics.CapDeferred += 1
			return nil
		end
	end

	-- Re-validate the spot: boats/docks may have drifted over it, and an
	-- island may have risen nearby since the record was cached. The record's
	-- own octree node is ignored so it does not block itself.
	local spacingRadius = record.spacingRadius or 10
	if not isSpotClear(record.centerPos, spacingRadius, true, record) then
		diagnostics.BlockedSpot += 1
		record.blockedUntil = now + (streamingConfig.ObstacleRetryDelay or 25)
		return nil
	end

	local model = buildClone(record)
	if not model then
		diagnostics.CloneFailed += 1
		record.dead = true
		if record.node then
			recordOctree:RemoveNode(record.node)
			record.node = nil
		end
		return nil
	end

	-- Seat the bounding-box center at its float height, with the record yaw.
	-- The height uses the ACTUAL surface, not the mean waterline: spawning on
	-- PLANE_Y meant every prop had to be dragged up out of a trough (or dropped
	-- into one) the instant it appeared, which is exactly the pop-in the ship
	-- never has because it is seated on the wave it is standing on.
	local _, bboxSize = model:GetBoundingBox()
	local buoyancyConfig = getBuoyancyConfig()
	local surfaceY = WaveFloat.HeightAt(
		record.centerPos,
		nil,
		buoyancyConfig.HeightSource or "ANALYTIC",
		buoyancyConfig.LookupMethod or "PRECISE",
		now
	) or PLANE_Y
	local pivotY = surfaceY + bboxSize.Y * ((record.floatRatio or 0.5) - 0.5)
	local pivot = CFrame.new(record.centerPos.X, pivotY, record.centerPos.Z) * CFrame.Angles(0, record.yaw, 0)
	model:PivotTo(pivot)

	-- Seed the cadence band so a PlaceOne()/debug spawn near a player starts
	-- in the near band instead of waiting for the next streaming cycle.
	local nearestPlayer, nearestSq = nearestPlayerInfo(record.centerPos)
	record.nearestPlayer = nearestPlayer
	record.nearestSq = nearestSq
	updateSimBand(record, nearestSq)

	record.model = model
	record.hull = model.PrimaryPart
	record.parts = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(record.parts, descendant)
		end
	end

	model:SetAttribute("FloatingClass", record.className)
	model:SetAttribute("FloatingCell", record.cellKey or "AdHoc")
	model:SetAttribute("GeneratedFloat", true)
	if not CollectionService:HasTag(model, Config.ObjectTag) then
		CollectionService:AddTag(model, Config.ObjectTag)
	end
	model.Parent = ensureContainerFolder()

	buildSim(record)

	recordsByModel[model] = record
	record.destroyingConnection = model.Destroying:Connect(function()
		-- External removal (admin tool, Studio): return to cache gracefully.
		if recordsByModel[model] == record then
			record.model = nil
			record.hull = nil
			record.parts = nil
			record.sim = nil
			disconnectRecordSignals(record)
			unmarkRendered(record)
			record.state = "Cached"
		end
	end)

	record.activatedAt = now
	record.expiresAt = now + (record.lifetime or 0)
	record.blockedUntil = nil
	record.unseenSince = nil
	markRendered(record)

	if wantFrozen or not isBuoyancyEnabled() then
		setObjectFrozen(record, true)
	else
		setObjectFrozen(record, false)
	end
	diagnostics.SpawnedTotal += 1

	return model
end

-- Render-cap enforcement ---------------------------------------------------------

-- Best record to cache when the render cap is full. Prefers objects with no
-- player nearby (frozen ones first - removing them interrupts no
-- simulation); falls back to the OLDEST rendered object.
-- An object is "in sight" when a player's camera can see it, or a player is
-- inside its simulation band. In-sight objects are never cached or expired to
-- make room or on a timer.
local function isInSight(record, now: number): boolean
	local pos = getRecordWorldPos(record)
	if isSeenByAnyCamera(pos, now, 15) then
		return true
	end
	local _, nearestSq = nearestPlayerInfo(pos)
	local simDistance = record.simDistance or 200
	return nearestSq <= simDistance * simDistance
end

local function getCullCandidate()
	local despawnConfig = getDespawnConfig()
	local protectDistance = despawnConfig.CullNearPlayerDistance or 260
	local now = getNow()

	local bestFar = nil
	local bestFarScore = -math.huge
	local oldest = nil
	local oldestAge = -math.huge

	for record in activeRecords do
		if isInSight(record, now) then
			continue
		end
		local pos = getRecordWorldPos(record)
		local nearestSq = distanceSqToNearestPlayer(pos)
		local age = now - (record.activatedAt or now)

		if age > oldestAge then
			oldestAge = age
			oldest = record
		end

		local protectedRadius = (record.spacingRadius or 10) + protectDistance
		if nearestSq > protectedRadius * protectedRadius then
			local score = nearestSq
			if record.state == "Frozen" then
				score += FROZEN_CULL_BONUS
			end
			if score > bestFarScore then
				bestFarScore = score
				bestFar = record
			end
		end
	end

	return bestFar or oldest
end

function enforceRenderedLimit(reserveSlots: number?)
	local maxRendered = getStreamingConfig().MaxRenderedObjects or 500
	local target = math.max(0, maxRendered - (reserveSlots or 0))

	while renderedCount > target do
		local candidate = getCullCandidate()
		if not candidate then
			break
		end
		cacheObjectRecord(candidate, "RenderLimit", false)
	end
end

FloatingObjectGenerator.enforceRenderedLimit = enforceRenderedLimit

-- Record generation ------------------------------------------------------------

local function makeObjectRecord(templateEntry, className: string, cfg, pos: Vector3, yaw: number, rng: Random)
	local despawnConfig = getDespawnConfig()
	local minLifetime = despawnConfig.MinLifetime or 30 * 60
	local maxLifetime = despawnConfig.MaxLifetime or 45 * 60
	if maxLifetime < minLifetime then
		maxLifetime = minLifetime
	end

	local floatRatio = cfg.FloatRatio
	local attributeRatio = templateEntry.instance:GetAttribute("FloatRatio")
	if typeof(attributeRatio) == "number" then
		floatRatio = math.clamp(attributeRatio, 0.05, 0.95)
	end

	local simDistance = cfg.SimDistance
	local attributeDistance = templateEntry.instance:GetAttribute("SimDistance")
	if typeof(attributeDistance) == "number" and attributeDistance > 0 then
		simDistance = attributeDistance
	end

	local spacingRadius = math.max(cfg.MinSpacing, templateEntry.extentXZ * 0.6)
	local seed = getCellSeed(math.floor(pos.X), math.floor(pos.Z)) + rng:NextInteger(0, 65535)

	local record = {
		key = nil,
		cellKey = nil,
		cx = nil,
		cz = nil,
		template = templateEntry.instance,
		className = className,
		centerPos = Vector3.new(pos.X, PLANE_Y, pos.Z),
		yaw = yaw,
		spacingRadius = spacingRadius,
		floatRatio = floatRatio,
		simDistance = simDistance,
		state = "Cached",
		createdAt = getNow(),
		lastTouched = getNow(),
		lifetime = Random.new(seed):NextNumber(minLifetime, maxLifetime),
	}
	return record
end

-- Deterministically evaluates one world cell: either a set of floating object
-- records, an empty marker, or nil (retry later - a movable obstacle is
-- currently blocking the spot).
local function generateCellRecords(cx: number, cz: number)
	local key = cellKey(cx, cz)
	if cellCache[key] ~= nil then
		return cellCache[key]
	end

	local now = getNow()
	local retryAt = blockedCellRetryAt[key]
	if retryAt and now < retryAt then
		return nil
	end

	local catalogList = getCatalogList()
	if #catalogList == 0 then
		return nil
	end

	local streamingConfig = getStreamingConfig()
	local pl = Config.Placement
	local cell = pl.CellSize or 150
	local rng = Random.new(getCellSeed(cx, cz))
	local emptyMarker = nil

	-- ROADMAP 7.1: objects follow the shared density field (archipelagos dense,
	-- open water sparse). ObjectChance is a global multiplier.
	local objectChance = pl.ObjectChance or 1
	local dc = pl.Density
	if dc and dc.Enabled ~= false then
		local t = Density.value(cx * cell, cz * cell, getWorldSeed(), dc.Scale or 1400)
		objectChance *= Density.chance(t, dc.MinChance or 0.15, dc.MaxChance or 0.75)
	end
	if rng:NextNumber() > objectChance then
		emptyMarker = true
	end

	local baseX, baseZ = cx * cell, cz * cell
	if not emptyMarker then
		local jitter = pl.GridJitter or 0
		baseX += rng:NextNumber(-cell * jitter, cell * jitter)
		baseZ += rng:NextNumber(-cell * jitter, cell * jitter)
		local distOrigin = math.sqrt(baseX * baseX + baseZ * baseZ)
		if distOrigin < (pl.SpawnSafetyRadius or 140) then
			emptyMarker = true
		elseif pl.RespectWorldRadius and distOrigin > (pl.WorldRadius or 2600) then
			emptyMarker = true
		end
	end

	local records = {}
	if not emptyMarker then
		local entry = weightedPickEntry(catalogList, rng)
		local cfg = classConfig(entry.name)
		local count = rng:NextInteger(math.min(cfg.PerCellMin, cfg.PerCellMax), cfg.PerCellMax)

		for _ = 1, count do
			local templateEntry = weightedPickEntry(entry.templates, rng)
			local accepted = false

			for _ = 1, (pl.MaxPlacementAttempts or 6) do
				local angle = rng:NextNumber(0, math.pi * 2)
				local dist = math.sqrt(rng:NextNumber()) * (cfg.ClusterRadius or 12)
				local x = baseX + math.cos(angle) * dist
				local z = baseZ + math.sin(angle) * dist
				local pos = Vector3.new(x, PLANE_Y, z)

				-- Octree/island checks are cheap, so re-roll on failure. The
				-- broadphase workspace query runs once, only when the spot is
				-- otherwise clear.
				if isSpotClear(pos, math.max(cfg.MinSpacing, templateEntry.extentXZ * 0.6), false) then
					if hasBlockingObstacle(pos, math.max(cfg.MinSpacing, templateEntry.extentXZ * 0.6)) then
						-- A movable obstacle (boat/dock) is parked here: retry
						-- the whole cell later instead of burning it. Undo the
						-- footprints reserved by this cell's earlier objects so
						-- the retry starts clean.
						for _, record in records do
							if record.node then
								recordOctree:RemoveNode(record.node)
								record.node = nil
							end
						end
						blockedCellRetryAt[key] = now + (streamingConfig.ObstacleRetryDelay or 25)
						return nil
					end

					local record =
						makeObjectRecord(templateEntry, entry.name, cfg, pos, rng:NextNumber(0, math.pi * 2), rng)
					record.key = key .. "#" .. #records
					record.cellKey = key
					record.cx = cx
					record.cz = cz
					table.insert(records, record)
					-- Reserve the footprint immediately so siblings in this
					-- cell (and later cells) keep their distance.
					record.node = recordOctree:CreateNode(Vector3.new(pos.X, PLANE_Y, pos.Z), {
						spacingRadius = record.spacingRadius,
						record = record,
					})
					accepted = true
					break
				end
			end

			if not accepted then
				continue -- this object's spot was taken; skip it
			end
		end
	end

	if #records == 0 then
		cellCache[key] = { empty = true, at = now, lastTouched = now }
	else
		cellCache[key] = { key = key, cx = cx, cz = cz, records = records, at = now, lastTouched = now }
	end
	blockedCellRetryAt[key] = nil
	return cellCache[key]
end

-- Streaming loop -----------------------------------------------------------------

local function forEachPlayerCell(radius: number, maxCells: number, callback)
	local roots = {}
	for _, player in Players:GetPlayers() do
		local root = getPlayerRoot(player)
		if root then
			table.insert(roots, root)
		end
	end
	if #roots == 0 then
		return 0
	end

	local cell = Config.Placement.CellSize or 150
	local radiusCells = math.ceil(radius / cell)
	local radiusSq = radius * radius
	local seen = {}
	local processed = 0

	for _, root in roots do
		local rootX = root.Position.X
		local rootZ = root.Position.Z
		local centerCx = math.floor(rootX / cell + 0.5)
		local centerCz = math.floor(rootZ / cell + 0.5)

		for ring = 0, radiusCells do
			for dx = -ring, ring do
				for dz = -ring, ring do
					if math.max(math.abs(dx), math.abs(dz)) ~= ring then
						continue
					end

					local cx = centerCx + dx
					local cz = centerCz + dz
					local key = cellKey(cx, cz)
					if seen[key] then
						continue
					end

					local cellCenterX = cx * cell
					local cellCenterZ = cz * cell
					local distX = cellCenterX - rootX
					local distZ = cellCenterZ - rootZ
					if distX * distX + distZ * distZ > radiusSq then
						continue
					end

					seen[key] = true
					processed += 1
					local shouldContinue = callback(cx, cz, key)
					if shouldContinue == false or processed >= maxCells then
						return processed
					end
				end
			end
		end
	end

	return processed
end

local function generateCellsAroundPlayers()
	local streamingConfig = getStreamingConfig()
	local maxCells = streamingConfig.MaxCellsPerCycle or 256
	local cellsPerYield = streamingConfig.CellsPerYield or 48
	local processed = 0

	forEachPlayerCell(streamingConfig.GenerationRadius or 1700, maxCells, function(cx, cz, key)
		if cellCache[key] == nil then
			generateCellRecords(cx, cz)
		end
		local cellRecord = cellCache[key]
		if cellRecord then
			cellRecord.lastTouched = getNow()
		end
		processed += 1
		if processed % cellsPerYield == 0 then
			task.wait()
		end
	end)
end

local function recordHasInterest(record, now: number): (boolean, boolean)
	-- Returns (hasInterest, wantFrozen). hasInterest=false means "cache it".
	local streamingConfig = getStreamingConfig()
	local cacheDistance = streamingConfig.CacheDistance or 650
	local pos = getRecordWorldPos(record)
	local nearestPlayer, nearestSq = nearestPlayerInfo(pos)
	local simDistance = record.simDistance or 200

	-- `setOwnership` runs in the same streaming cycle and reuses these instead
	-- of scanning the player list a second time per object.
	record.nearestPlayer = nearestPlayer
	record.nearestSq = nearestSq
	updateSimBand(record, nearestSq)

	-- Keep a clear ring around each player (Streaming.MinPlayerDistance) for
	-- objects that are not yet rendered. Rendered objects stay in the world.
	local minDistance = streamingConfig.MinPlayerDistance or 0
	if not record.rendered and nearestSq < minDistance * minDistance then
		record.unseenSince = nil
		return false, false
	end

	if nearestSq > cacheDistance * cacheDistance then
		return false, false
	end
	if nearestSq <= simDistance * simDistance then
		record.unseenSince = nil
		return true, false
	end

	-- Middle band: out of simulation range but possibly visible.
	if not hasFreshCamera(now) then
		record.unseenSince = nil
		return true, true -- distance-only fallback: keep rendered, frozen
	end
	if isSeenByAnyCamera(pos, now, record.rendered and 15 or nil) then
		record.unseenSince = nil
		return true, true
	end

	-- Unseen by every fresh camera: run the grace timer out, then cache.
	-- (The timer lives on the record and must NOT be reset by callers while
	-- the object is merely inside the grace window.)
	if record.unseenSince == nil then
		record.unseenSince = now
	elseif now - record.unseenSince > (streamingConfig.OutOfViewGrace or 3) then
		return false, false
	end
	return true, true
end

local function activateRecordsAroundPlayers()
	local streamingConfig = getStreamingConfig()
	local maxSpawns = streamingConfig.MaxSpawnsPerCycle or 24
	local cell = Config.Placement.CellSize or 150
	local activationRadius = (streamingConfig.CacheDistance or 650) + cell
	local spawned = 0
	local now = getNow()

	forEachPlayerCell(activationRadius, streamingConfig.MaxActivationCellsPerCycle or 320, function(_, _, key)
		if spawned >= maxSpawns then
			return false
		end

		local cellRecord = cellCache[key]
		if not cellRecord or cellRecord.empty then
			return nil
		end

		for _, record in cellRecord.records do
			if spawned >= maxSpawns then
				break
			end
			if record.dead or record.rendered then
				continue
			end

			local hasInterest, wantFrozen = recordHasInterest(record, now)
			if hasInterest then
				if spawnRecord(record, wantFrozen) then
					spawned += 1
				end
			end
		end
		return nil
	end)
end

local function updateActiveLOD()
	local streamingConfig = getStreamingConfig()
	local maxCaches = streamingConfig.MaxCachesPerCycle or 64
	local cachedCount = 0
	local now = getNow()

	for record in activeRecords do
		local hasInterest, wantFrozen = recordHasInterest(record, now)
		if not hasInterest then
			if cachedCount < maxCaches then
				cachedCount += 1
				cacheObjectRecord(record, "Unseen", false)
			end
		else
			local shouldFreeze = wantFrozen or not isBuoyancyEnabled()
			if shouldFreeze and record.state == "Buoyant" then
				setObjectFrozen(record, true)
			elseif not shouldFreeze and record.state == "Frozen" then
				setObjectFrozen(record, false)
			elseif not shouldFreeze then
				-- Already buoyant: keep network ownership in step with the
				-- players moving around it. A no-op unless the mode is
				-- "NearestPlayer" and the closest client actually changed.
				setOwnership(record, true)
			end
		end
	end
end

local function updateLifetimeDespawns()
	local now = getNow()
	local expired = {}
	for record in activeRecords do
		if record.expiresAt and now >= record.expiresAt then
			if isInSight(record, now) then
				-- Never expire an object a player can see; check again shortly.
				record.expiresAt = now + 10
			else
				table.insert(expired, record)
			end
		end
	end
	for _, record in expired do
		cacheObjectRecord(record, "Lifetime", true)
	end
end

-- Drops cache cells no player has touched for a long time. Records are
-- deterministic, so a trimmed cell re-evaluates identically when a player
-- returns - trimming is effectively free memory reclaim.
local function trimIdleCells(now: number)
	local streamingConfig = getStreamingConfig()
	local interval = streamingConfig.CacheTrimInterval or 90
	if now - lastTrimAt < interval then
		return
	end
	lastTrimAt = now

	local idleLifetime = streamingConfig.CellIdleLifetime or 600
	local keepRadius = (streamingConfig.GenerationRadius or 1700) + (streamingConfig.CacheTrimMargin or 256)
	local cell = Config.Placement.CellSize or 150
	local keepRadiusSq = keepRadius * keepRadius

	local trimKeys = nil
	for key, cellRecord in cellCache do
		if now - (cellRecord.lastTouched or cellRecord.at or now) <= idleLifetime then
			continue
		end
		if cellRecord.empty then
			trimKeys = trimKeys or {}
			table.insert(trimKeys, key)
			continue
		end

		local centerX = (cellRecord.cx or 0) * cell
		local centerZ = (cellRecord.cz or 0) * cell

		local nearPlayer = false
		for _, player in Players:GetPlayers() do
			local root = getPlayerRoot(player)
			if root then
				local dx = root.Position.X - centerX
				local dz = root.Position.Z - centerZ
				if dx * dx + dz * dz <= keepRadiusSq then
					nearPlayer = true
					break
				end
			end
		end
		if nearPlayer then
			continue
		end

		local hasRendered = false
		for _, record in cellRecord.records do
			if record.rendered then
				hasRendered = true
				break
			end
		end
		if hasRendered then
			continue
		end

		for _, record in cellRecord.records do
			record.dead = true
			if record.node then
				recordOctree:RemoveNode(record.node)
				record.node = nil
			end
		end
		trimKeys = trimKeys or {}
		table.insert(trimKeys, key)
	end

	if trimKeys then
		for _, key in trimKeys do
			cellCache[key] = nil
		end
	end

	for key, retryAt in blockedCellRetryAt do
		if retryAt < now - idleLifetime then
			blockedCellRetryAt[key] = nil
		end
	end
end

local function streamingStep()
	local now = getNow()
	generateCellsAroundPlayers()
	activateRecordsAroundPlayers()
	updateActiveLOD()
	updateLifetimeDespawns()
	FloatingObjectGenerator.enforceRenderedLimit(0)
	trimIdleCells(now)
end

local function startStreamingLoop()
	if streamingLoopRunning then
		return
	end

	generationToken += 1
	local token = generationToken
	streamingLoopRunning = true

	task.spawn(function()
		local streamingConfig = getStreamingConfig()
		print(
			"[FloatingObjectGenerator] dynamic streaming started. Render cap: "
				.. tostring(streamingConfig.MaxRenderedObjects or 500)
		)

		while generationToken == token do
			local ok, err = pcall(streamingStep)
			if not ok then
				warn("[FloatingObjectGenerator] streaming step failed: " .. tostring(err))
			end
			task.wait(getStreamingConfig().GenerationInterval or 1.25)
		end

		if generationToken == token then
			streamingLoopRunning = false
		end
	end)
end

-- Frame-budgeted buoyancy scheduler ------------------------------------------------

--[[
	Refreshes due buoyancy targets every frame, in two classes:

		* the near band (an object a player is standing next to, where the
		  waterline is legible) is refreshed every step with the ship's gains -
		  same as `Ship.Client`;
		* everything else rides its staggered `nextUpdateAt` clock.

	Both classes have their own per-frame budget, and an object that runs out of
	near-band budget is not skipped: it falls through to the staggered class and
	is serviced there, so a crowded dock cannot starve the props behind it.
]]
local function startBuoyancyLoop()
	if buoyancyConnection then
		return
	end

	buoyancyConnection = RunService.PostSimulation:Connect(function()
		local now = getNow()
		local buoyancyConfig = getBuoyancyConfig()
		local nearBudget = buoyancyConfig.NearMaxTargetUpdatesPerFrame or 24
		local budget = buoyancyConfig.MaxTargetUpdatesPerFrame or 48

		for record in buoyantRecords do
			local sim = record.sim
			if sim and record.state == "Buoyant" then
				local near = record.nearPlayer == true and nearBudget > 0
				if near then
					nearBudget -= 1
				elseif now < (sim.nextUpdateAt or 0) or budget <= 0 then
					continue
				else
					budget -= 1
				end
				applyBuoyancyTarget(record, now, near, buoyancyConfig)
			end
		end
	end)
end

-- Workspace seeding -----------------------------------------------------------------

-- Seeds the record octree with floating objects a user placed by hand (tagged
-- Config.ObjectTag) so generated objects keep their distance from them.
local function seedOctreeFromWorkspace()
	for _, instance in CollectionService:GetTagged(Config.ObjectTag) do
		if not instance:IsDescendantOf(Workspace) then
			continue
		end
		local pos: Vector3
		if instance:IsA("Model") then
			pos = instance:GetPivot().Position
		elseif instance:IsA("BasePart") then
			pos = instance.Position
		else
			continue
		end
		recordOctree:CreateNode(Vector3.new(pos.X, PLANE_Y, pos.Z), {
			spacingRadius = math.max(templateExtentXZ(instance) * 0.6, 10),
			existing = true,
		})
	end
	seededFromWorkspace = true
end

-- Public API -------------------------------------------------------------------------

-- Rebuilds and returns the class catalog found under ServerStorage.
function FloatingObjectGenerator.GetCatalog()
	if catalog == nil then
		buildCatalog()
	end
	local summary = {}
	for className, entry in catalog do
		summary[className] = {
			weight = entry.weight,
			templateCount = #entry.templates,
		}
	end
	return summary
end

-- Starts dynamic streaming of floating objects around moving players.
function FloatingObjectGenerator.Generate()
	local catalogList = getCatalogList()
	if #catalogList == 0 then
		warn(
			"[FloatingObjectGenerator] No tagged templates found under ServerStorage."
				.. Config.TemplatesRoot
				.. " (expected tags: Small, Medium, Large, Debris)."
		)
		return
	end

	ensureContainerFolder()
	if not seededFromWorkspace then
		seedOctreeFromWorkspace()
	end

	if isBuoyancyEnabled() then
		startBuoyancyLoop()
	end

	if getStreamingConfig().Enabled ~= false then
		startStreamingLoop()
	end
end

-- Places a single floating object at `position` (debug/admin). `className`
-- optionally picks the size class; otherwise a weighted class is chosen.
-- Returns the spawned Model, or nil if the spot was blocked.
function FloatingObjectGenerator.PlaceOne(position: Vector3, className: string?): Model?
	local catalogList = getCatalogList()
	if #catalogList == 0 then
		return nil
	end

	local entry
	if className then
		for _, candidate in catalogList do
			if candidate.name == className then
				entry = candidate
				break
			end
		end
		if not entry then
			warn("[FloatingObjectGenerator] unknown class '" .. tostring(className) .. "' for PlaceOne")
			return nil
		end
	else
		entry = catalogList[math.random(1, #catalogList)]
	end

	local rng = Random.new(getWorldSeed() + math.random(1, 100000))
	local templateEntry = weightedPickEntry(entry.templates, rng)
	local cfg = classConfig(entry.name)
	local spacingRadius = math.max(cfg.MinSpacing, templateEntry.extentXZ * 0.6)
	local pos = Vector3.new(position.X, PLANE_Y, position.Z)

	if not isSpotClear(pos, spacingRadius, true) then
		return nil
	end

	local record = makeObjectRecord(templateEntry, entry.name, cfg, pos, rng:NextNumber(0, math.pi * 2), rng)
	record.node = recordOctree:CreateNode(Vector3.new(pos.X, PLANE_Y, pos.Z), {
		spacingRadius = record.spacingRadius,
		record = record,
	})
	table.insert(placedRecords, record)
	return spawnRecord(record, false)
end

-- Camera interest feed. The server script forwards validated
-- CameraReport RemoteEvent payloads here (client -> server).
function FloatingObjectGenerator.SetCameraState(player: Player, cameraPos: Vector3, cameraLook: Vector3)
	if typeof(cameraPos) ~= "Vector3" or typeof(cameraLook) ~= "Vector3" then
		return
	end

	-- NaN components never equal themselves; reject poisoned vectors.
	if
		cameraPos.X ~= cameraPos.X
		or cameraPos.Y ~= cameraPos.Y
		or cameraPos.Z ~= cameraPos.Z
		or cameraLook.X ~= cameraLook.X
		or cameraLook.Y ~= cameraLook.Y
		or cameraLook.Z ~= cameraLook.Z
	then
		return
	end

	local lookMagnitude = cameraLook.Magnitude
	if lookMagnitude < 0.5 or lookMagnitude > 2 then
		return -- clients must send a unit-ish look vector
	end
	if math.abs(cameraPos.X) > 1e5 or math.abs(cameraPos.Y) > 1e5 or math.abs(cameraPos.Z) > 1e5 then
		return -- reject absurd positions (exploit hardening)
	end

	cameraStates[player] = {
		pos = cameraPos,
		look = cameraLook / lookMagnitude,
		at = getNow(),
	}
end

-- Clears camera interest (and any simulated-prop tally) for a leaving player.
-- Wire to Players.PlayerRemoving.
function FloatingObjectGenerator.RemovePlayer(player: Player)
	cameraStates[player] = nil
	ownedCountByPlayer[player] = nil
	for record in activeRecords do
		if record.owner == player then
			record.owner = nil
		end
	end
end

-- ROADMAP 7.1 (diagnostics): cached, live object records within `radius` of a
-- position. Read-only.
function FloatingObjectGenerator.CountNearby(position: Vector3, radius: number): number
	local center = Vector3.new(position.X, PLANE_Y, position.Z)
	local count = 0
	for _, node in recordOctree:SearchRadius(center, radius) do
		local record = node.Object and node.Object.record
		if record == nil or not record.dead then
			count += 1
		end
	end
	return count
end

function FloatingObjectGenerator.GetStats()
	local cachedCells = 0
	local cachedRecords = 0
	local buoyant = 0
	local frozen = 0
	local now = getNow()
	local timeout = getStreamingConfig().CameraDataTimeout or 3
	local freshCameras = 0
	for _, state in cameraStates do
		if now - state.at <= timeout then
			freshCameras += 1
		end
	end
	for _, cellRecord in cellCache do
		if not cellRecord.empty then
			cachedCells += 1
			for _, record in cellRecord.records do
				if not record.dead then
					cachedRecords += 1
					if record.state == "Buoyant" then
						buoyant += 1
					elseif record.state == "Frozen" then
						frozen += 1
					end
				end
			end
		end
	end
	return {
		CachedCells = cachedCells,
		CachedRecords = cachedRecords,
		RenderedObjects = renderedCount,
		BuoyantObjects = buoyant,
		FrozenObjects = frozen,
		MaxRenderedObjects = getStreamingConfig().MaxRenderedObjects or 500,
		Streaming = streamingLoopRunning,
		CacheReasons = cacheCounts,
		FreshCameras = freshCameras,
		NearBandStuds = getBuoyancyConfig().NearDistance or 150,
		ClientOwnedObjects = clientOwnedCount(),
		Diagnostics = diagnostics,
	}
end

-- Removes every floating object this generator rendered and resets all
-- streaming/cache/octree state. Hand-placed tagged objects are untouched
-- (only their octree seed nodes are cleared). Call Generate() to restart.
function FloatingObjectGenerator.ClearGenerated()
	generationToken += 1
	streamingLoopRunning = false

	if buoyancyConnection then
		buoyancyConnection:Disconnect()
		buoyancyConnection = nil
	end

	local toDestroy = {}
	for record in activeRecords do
		table.insert(toDestroy, record)
	end
	for _, record in toDestroy do
		cacheObjectRecord(record, "Clear", false)
	end
	for _, record in placedRecords do
		if record.model then
			cacheObjectRecord(record, "Clear", true)
		end
	end

	for _, cellRecord in cellCache do
		if not cellRecord.empty then
			for _, record in cellRecord.records do
				record.dead = true
			end
		end
	end

	table.clear(cellCache)
	table.clear(blockedCellRetryAt)
	table.clear(ownedCountByPlayer)
	table.clear(activeRecords)
	table.clear(buoyantRecords)
	table.clear(recordsByModel)
	table.clear(placedRecords)
	renderedCount = 0

	recordOctree:ClearAllNodes()
	seededFromWorkspace = false
	catalog = nil -- force re-discovery on next Generate
	lastTrimAt = 0
end

return FloatingObjectGenerator
