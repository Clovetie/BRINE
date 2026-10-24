--!nonstrict
--!optimize 2

--[[
	IslandGenerator
	===============
	Streams PREMADE islands into the world. Islands are authored as complete
	Models inside ServerStorage.Islands (a folder of biome folders; each biome
	folder may contain arbitrarily-nested folders of island Models). The
	generator does NOT generate geometry, noise, or structures - it only discovers
	templates, picks them, caches lightweight island records per world cell, and
	clones/renders those cached records near moving players.

	Dynamic streaming model:
		* A deterministic cell record is created once, then cached for the server
		  lifetime. The cache may grow as far as players travel.
		* Actual Model clones are only created when a player comes close enough to
		  see an island rise. This keeps memory/replication cost bounded.
		* At most Config.Streaming.MaxRenderedIslands generated islands are allowed
		  to be rendered at once. The cached total can exceed that cap.
		* Rendered islands despawn after Config.Despawn.MinLifetime..MaxLifetime
		  seconds, and old/far rendered islands can be culled when the render cap is
		  reached. Despawned/cull targets sink first when a player is nearby.

	Collision safety ("NEVER collides"): every candidate is validated BEFORE it is
	cached. A spot is clear only if:
		(a) it is far enough from every cached/placed island (octree), and
		(b) it overlaps no non-ocean / non-map BaseParts (boats, props, baseplate...)
		    via Workspace:GetPartBoundsInRadius. Player characters are excluded from
		    this broadphase check so a moving player does not permanently block a
		    deterministic cell.

	References (official docs):
		ServerStorage         https://create.roblox.com/docs/reference/engine/classes/ServerStorage
		Instance              https://create.roblox.com/docs/reference/engine/classes/Instance
		Model / PVInstance    https://create.roblox.com/docs/studio/pivot-tools
		CollectionService     https://create.roblox.com/docs/reference/engine/classes/CollectionService
		TweenService          https://create.roblox.com/docs/reference/engine/classes/TweenService
		Sound                 https://create.roblox.com/docs/reference/engine/classes/Sound
		Task scheduler        https://create.roblox.com/docs/scripting/scheduler
		WorldRoot bounds      https://create.roblox.com/docs/reference/engine/classes/WorldRoot
		OverlapParams         https://create.roblox.com/docs/reference/engine/datatypes/OverlapParams
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.IslandConfig)
local OctreeModule = require(ReplicatedStorage.Octree)

local PLANE_Y = Config.PlaneOffset
local TAG = "Island"
local RISING_ISLANDS_FOLDER_NAME = "_RisingIslands"
local NO_ISLAND = false
local ASSET_ID_PREFIX = "rbxassetid://"
local HASH_MOD = 2147483647
local HASH_X = 73856093
local HASH_Z = 19349663

local IslandGenerator = {}

-- Octree of every island footprint we must avoid: cached generated records plus
-- any user-authored islands already sitting in workspace.Map.
local islandOctree = OctreeModule.new()

-- Cached generation state. cellCache[key] is either an island record table or
-- NO_ISLAND. nil means the cell has not been evaluated yet.
local cellCache = {}
local blockedCellRetryAt = {}
local allGeneratedRecords = {}

-- Rendered/runtime state. A record is "rendered" while its model is in
-- Workspace (_RisingIslands or Map), including while sinking.
local activeRecords = {}
local recordsByModel = {}
local activeRiseTweens = {}
local activeSinkTweens = {}
local renderedRecordCount = 0

-- Catalog / loop state.
local catalog = nil
local mapSeeded = false
local streamingLoopRunning = false
local generationToken = 0
local cachedWorldSeed = nil

-- OverlapParams used by the obstacle check. FilterDescendantsInstances is kept
-- fresh before each query so Map/Ocean/rising islands/player characters are not
-- treated as blockers.
local obstacleParams = OverlapParams.new()
obstacleParams.FilterType = Enum.RaycastFilterType.Exclude
obstacleParams.RespectCanCollide = false -- also treat CanQuery-only decor as blockers
obstacleParams.MaxParts = 64 -- bound the query; any hit (> 0) already blocks
obstacleParams.FilterDescendantsInstances = {}

-- Config helpers ---------------------------------------------------------------

local function getStreamingConfig()
	return Config.Streaming or {}
end

local function getRiseConfig()
	return Config.Rising or {}
end

local function getDespawnConfig()
	return Config.Despawn or {}
end

local function isStreamingEnabled(): boolean
	local streamingConfig = Config.Streaming
	return streamingConfig == nil or streamingConfig.Enabled ~= false
end

local function isRisingEnabled(): boolean
	local riseConfig = Config.Rising
	return riseConfig ~= nil and riseConfig.Enabled ~= false
end

local function getCellSize(): number
	local streamingConfig = getStreamingConfig()
	return streamingConfig.CellSize or Config.Placement.CellSize
end

local function getNow(): number
	return Workspace:GetServerTimeNow()
end

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

local function ensureRisingIslandFolder(): Folder
	return getOrCreateFolder(Workspace, RISING_ISLANDS_FOLDER_NAME)
end

-- Reads the world seed from the SAME IntValue the ocean uses
-- (ReplicatedStorage.Gerstner.Settings.Seed). Settings reseeds that value once
-- when it is 0 and persists it, so by the time we require Settings the value is
-- stable across server restarts. A fixed fallback keeps us deterministic even if
-- the IntValue is somehow missing or zero.
local function getWorldSeed(): number
	if cachedWorldSeed ~= nil then
		return cachedWorldSeed
	end

	local seedValue = 0
	local ok, valueScript = pcall(function()
		return ReplicatedStorage.Gerstner.Settings:FindFirstChild("Seed")
	end)
	if ok and valueScript and valueScript:IsA("IntValue") and valueScript.Value ~= 0 then
		seedValue = valueScript.Value
	else
		seedValue = 7919
	end
	cachedWorldSeed = seedValue
	return seedValue
end

local function cellKey(cx: number, cz: number): string
	return tostring(cx) .. ":" .. tostring(cz)
end

local function getCellSeed(cx: number, cz: number): number
	local seed = (getWorldSeed() + cx * HASH_X + cz * HASH_Z) % HASH_MOD
	if seed < 0 then
		seed += HASH_MOD
	end
	return math.floor(seed)
end

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

-- workspace.Map is the folder the ocean depth raycasts include and ZoneManager
-- scans; the generator must place risen islands there. It also tells the
-- obstacle query which folders to ignore so it never flags water/terrain as an
-- obstacle.
local function ensureMapFolder(): Folder
	local map = Workspace:FindFirstChild("Map")
	if not map then
		map = Instance.new("Folder")
		map.Name = "Map"
		map.Parent = Workspace
	end
	refreshObstacleFilters(map)
	return map
end

-- Catalog / discovery ----------------------------------------------------------

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

-- Placement validation ---------------------------------------------------------

local function hasBlockingObstacle(centerPos: Vector3, radius: number): boolean
	local pl = Config.Placement
	refreshObstacleFilters()
	local parts = Workspace:GetPartBoundsInRadius(centerPos, radius + pl.ObstaclePadding, obstacleParams)
	return #parts > 0
end

-- True if `centerPos` (with footprint `radius`) is a safe, non-overlapping spot.
-- Pass `ignoredRecord` when checking a cached record against the octree that
-- already contains that same record's footprint node.
local function isSpotClear(centerPos: Vector3, radius: number, ignoredRecord: any?, checkObstacles: boolean?): boolean
	local pl = Config.Placement

	-- (1) Island overlap via octree.
	local searchRadius = radius + pl.SpacingPadding + pl.MaxIslandRadius
	for _, node in islandOctree:SearchRadius(centerPos, searchRadius) do
		local object = node.Object or {}
		if object.record ~= ignoredRecord then
			local otherR = object.radius or object.Radius or 0
			if (node.Position - centerPos).Magnitude < radius + otherR + pl.SpacingPadding then
				return false
			end
		end
	end

	-- (2) Obstacles via broadphase sphere query.
	if checkObstacles ~= false and hasBlockingObstacle(centerPos, radius) then
		return false
	end

	return true
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

local function getPlayerRoots(): { BasePart }
	local roots = {}
	for _, player in Players:GetPlayers() do
		local root = getPlayerRoot(player)
		if root then
			table.insert(roots, root)
		end
	end
	return roots
end

local function isAnyPlayerWithin(centerPos: Vector3, radius: number): boolean
	local radiusSq = radius * radius
	for _, player in Players:GetPlayers() do
		local root = getPlayerRoot(player)
		if root then
			local dx = root.Position.X - centerPos.X
			local dz = root.Position.Z - centerPos.Z
			if dx * dx + dz * dz <= radiusSq then
				return true
			end
		end
	end
	return false
end

local function isAnyPlayerCloseEnoughToRise(record): boolean
	local riseConfig = getRiseConfig()
	return isAnyPlayerWithin(record.centerPos, record.radius + (riseConfig.TriggerDistance or 0))
end

local function distanceSqToNearestPlayer(centerPos: Vector3): number
	local best = math.huge
	for _, player in Players:GetPlayers() do
		local root = getPlayerRoot(player)
		if root then
			local dx = root.Position.X - centerPos.X
			local dz = root.Position.Z - centerPos.Z
			local distSq = dx * dx + dz * dz
			if distSq < best then
				best = distSq
			end
		end
	end
	return best
end

-- Sound / tween helpers --------------------------------------------------------

local function normalizeSoundId(soundId): string
	local soundIdType = type(soundId)
	if soundIdType == "number" then
		return ASSET_ID_PREFIX .. tostring(soundId)
	elseif soundIdType == "string" then
		if soundId == "" then
			return ""
		end
		if tonumber(soundId) then
			return ASSET_ID_PREFIX .. soundId
		end
		return soundId
	end
	return ""
end

local function playConfiguredSound(model: Model, soundConfig, soundName: string)
	local soundId = normalizeSoundId(soundConfig.SoundId)
	if soundId == "" then
		return
	end

	local parent: Instance = model.PrimaryPart or model:FindFirstChild(Config.CenterPartName) or model
	local sound = Instance.new("Sound")
	sound.Name = soundName
	sound.SoundId = soundId
	sound.Volume = soundConfig.SoundVolume or 0.8
	sound.RollOffMaxDistance = soundConfig.SoundRollOffMaxDistance or 500
	sound.Parent = parent
	sound:Play()

	local cleanupDelay = math.max(soundConfig.SoundCleanupDelay or 10, (soundConfig.TweenTime or 4) + 10)
	Debris:AddItem(sound, cleanupDelay)
end

local function makeTweenInfo(tweenConfig, defaultStyle, defaultDirection): TweenInfo
	return TweenInfo.new(
		math.max(0.05, tweenConfig.TweenTime or 4),
		tweenConfig.EasingStyle or defaultStyle,
		tweenConfig.EasingDirection or defaultDirection
	)
end

local function cleanupPivotTween(tweenStore, record)
	local active = tweenStore[record]
	if not active then
		return
	end

	tweenStore[record] = nil
	if active.completedConnection then
		active.completedConnection:Disconnect()
	end
	if active.changedConnection then
		active.changedConnection:Disconnect()
	end
	if active.tween then
		active.tween:Cancel()
	end
	if active.pivotValue then
		active.pivotValue:Destroy()
	end
end

local function tweenModelPivot(record, tweenStore, tweenInfo: TweenInfo, goalPivot: CFrame, onCompleted)
	local model = record.model
	if not model or not model.Parent then
		return nil
	end

	cleanupPivotTween(tweenStore, record)

	local pivotValue = Instance.new("CFrameValue")
	pivotValue.Value = model:GetPivot()

	local changedConnection = pivotValue:GetPropertyChangedSignal("Value"):Connect(function()
		if model.Parent then
			model:PivotTo(pivotValue.Value)
		end
	end)

	local tween = TweenService:Create(pivotValue, tweenInfo, {
		Value = goalPivot,
	})
	local active = {
		tween = tween,
		pivotValue = pivotValue,
		changedConnection = changedConnection,
		completedConnection = nil,
	}
	tweenStore[record] = active

	local completedConnection
	completedConnection = tween.Completed:Connect(function(playbackState)
		if completedConnection then
			completedConnection:Disconnect()
		end
		if changedConnection then
			changedConnection:Disconnect()
		end
		if pivotValue then
			pivotValue:Destroy()
		end
		tweenStore[record] = nil

		if playbackState == Enum.PlaybackState.Completed then
			onCompleted()
		end
	end)
	active.completedConnection = completedConnection

	tween:Play()
	return tween
end

-- Record/model lifecycle -------------------------------------------------------

local function markRendered(record)
	if record.rendered then
		return
	end
	record.rendered = true
	renderedRecordCount += 1
	activeRecords[record] = true
end

local function unmarkRendered(record)
	if not record.rendered then
		return
	end
	record.rendered = false
	renderedRecordCount = math.max(0, renderedRecordCount - 1)
	activeRecords[record] = nil
end

local function tagIsland(model: Model)
	if not CollectionService:HasTag(model, TAG) then
		CollectionService:AddTag(model, TAG)
	end
end

local function untagIsland(model: Model)
	if CollectionService:HasTag(model, TAG) then
		CollectionService:RemoveTag(model, TAG)
	end
end

local function publishRisenIsland(record)
	local model = record.model
	if not model or not model.Parent then
		return
	end

	model.Parent = ensureMapFolder()
	model:SetAttribute("IslandRising", false)
	model:SetAttribute("IslandRisen", true)
	model:SetAttribute("IslandSinking", false)
	tagIsland(model)
	record.state = "Rendered"
end

local function getRecordLifetime(record, rng: Random?): number
	local despawnConfig = getDespawnConfig()
	local minLifetime = despawnConfig.MinLifetime or 35 * 60
	local maxLifetime = despawnConfig.MaxLifetime or 60 * 60
	if maxLifetime < minLifetime then
		maxLifetime = minLifetime
	end
	if rng then
		return rng:NextNumber(minLifetime, maxLifetime)
	end
	return Random.new(getCellSeed(record.cx or 0, record.cz or 0) + 17):NextNumber(minLifetime, maxLifetime)
end

-- Drops the given records from allGeneratedRecords in one pass (ROADMAP 4.1).
local function removeGeneratedRecords(removed: { [any]: boolean })
	local kept = {}
	for _, record in allGeneratedRecords do
		if not removed[record] then
			table.insert(kept, record)
		end
	end
	table.clear(allGeneratedRecords)
	table.move(kept, 1, #kept, 1, allGeneratedRecords)
end

local function destroyRecordModel(record, permanent: boolean, cooldownSeconds: number?)
	cleanupPivotTween(activeRiseTweens, record)
	cleanupPivotTween(activeSinkTweens, record)

	local model = record.model
	if model then
		untagIsland(model)
		recordsByModel[model] = nil
		if model.Parent then
			model:Destroy()
		end
	end

	record.model = nil
	record.finalPivot = nil
	record.hiddenPivot = nil
	record.activatedAt = nil
	record.expiresAt = nil
	unmarkRendered(record)

	if permanent then
		record.state = "Despawned"
		record.permanentlyDespawned = true
		record.despawnedAt = getNow()
		if record.node then
			islandOctree:RemoveNode(record.node)
			record.node = nil
		end
		-- ROADMAP 4.1: a permanently despawned cell keeps only its "no island"
		-- marker. The record is dropped, so expired islands do not pile up for the
		-- whole session. The cell still never regenerates.
		if record.key and cellCache[record.key] == record then
			cellCache[record.key] = NO_ISLAND
		end
		removeGeneratedRecords({ [record] = true })
	else
		record.state = "Cached"
		record.cullCooldownUntil = getNow() + (cooldownSeconds or 0)
	end
end

local function cloneRecordModel(record): Model?
	if record.model and record.model.Parent then
		return record.model
	end
	if not record.template or not record.template:IsA("Model") then
		return nil
	end

	local clone = record.template:Clone()
	local center = ensureCenter(clone)
	local radius = record.radius

	-- Reposition the clone so its Center part lands exactly on record.centerPos,
	-- preserving the template's internal offsets and applying the cached yaw.
	local pivot = clone:GetPivot()
	local offset = center.Position - pivot.Position
	local rotation = CFrame.Angles(0, record.yaw, 0)
	local newPivot = record.centerPos - (rotation * offset)
	local finalPivot = CFrame.new(newPivot) * rotation
	clone:PivotTo(finalPivot)

	-- Anchor the whole island so it is static and never sinks/falls in the ocean.
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

	clone:SetAttribute("Biome", record.biomeName)
	clone:SetAttribute("Premade", record.template.Name)
	clone:SetAttribute("IslandCellKey", record.key or "AdHoc")
	clone:SetAttribute("IslandCached", true)
	clone:SetAttribute("IslandRising", false)
	clone:SetAttribute("IslandRisen", false)
	clone:SetAttribute("IslandSinking", false)
	clone:SetAttribute("IslandRiseTriggerRadius", radius + ((Config.Rising and Config.Rising.TriggerDistance) or 0))

	record.model = clone
	record.finalPivot = finalPivot
	record.hiddenPivot = finalPivot + Vector3.new(0, -(getRiseConfig().HiddenDepth or 90), 0)
	recordsByModel[clone] = record
	return clone
end

local function beginIslandSink(record, reason: string, permanent: boolean)
	if record.state == "Sinking" then
		return
	end

	local model = record.model
	if not model or not model.Parent then
		destroyRecordModel(record, permanent, getDespawnConfig().CullCooldown)
		return
	end

	cleanupPivotTween(activeRiseTweens, record)
	untagIsland(model)

	local despawnConfig = getDespawnConfig()
	local nearDistance = record.radius + (despawnConfig.NearPlayerDistance or despawnConfig.NearDistance or 300)
	local shouldAnimate = isAnyPlayerWithin(record.centerPos, nearDistance)

	if not shouldAnimate then
		destroyRecordModel(record, permanent, despawnConfig.CullCooldown)
		return
	end

	record.state = "Sinking"
	record.despawnReason = reason
	model.Parent = ensureRisingIslandFolder()
	model:SetAttribute("IslandRising", false)
	model:SetAttribute("IslandRisen", false)
	model:SetAttribute("IslandSinking", true)
	model:SetAttribute("IslandDespawnReason", reason)

	playConfiguredSound(model, despawnConfig, "IslandSinkingSound")

	local sinkDepth = math.max(0, despawnConfig.SinkDepth or getRiseConfig().HiddenDepth or 90)
	local goalPivot = model:GetPivot() + Vector3.new(0, -sinkDepth, 0)
	local tweenInfo = makeTweenInfo(despawnConfig, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	tweenModelPivot(record, activeSinkTweens, tweenInfo, goalPivot, function()
		destroyRecordModel(record, permanent, despawnConfig.CullCooldown)
	end)
end

local function getCullCandidate()
	local despawnConfig = getDespawnConfig()
	local protectDistance = despawnConfig.CullNearPlayerDistance or despawnConfig.NearPlayerDistance or despawnConfig.NearDistance or 300
	local bestFarRecord = nil
	local bestFarScore = -math.huge
	local bestAnyRecord = nil
	local bestAnyScore = -math.huge

	for record, _ in activeRecords do
		if record.state ~= "Sinking" then
			local nearestSq = distanceSqToNearestPlayer(record.centerPos)
			local score = nearestSq + (getNow() - (record.activatedAt or getNow()))
			if score > bestAnyScore then
				bestAnyScore = score
				bestAnyRecord = record
			end

			local protectedRadius = record.radius + protectDistance
			if nearestSq > protectedRadius * protectedRadius and score > bestFarScore then
				bestFarScore = score
				bestFarRecord = record
			end
		end
	end

	return bestFarRecord or bestAnyRecord
end

local function enforceRenderedLimit(reserveSlots: number?)
	local streamingConfig = getStreamingConfig()
	local maxRendered = streamingConfig.MaxRenderedIslands or 200
	local target = math.max(0, maxRendered - (reserveSlots or 0))

	while renderedRecordCount > target do
		local candidate = getCullCandidate()
		if not candidate then
			break
		end
		beginIslandSink(candidate, "RenderLimit", false)
		-- If the candidate is near a player it will animate and still count as
		-- rendered until the sink tween completes, so avoid a tight loop.
		if candidate.state == "Sinking" then
			break
		end
	end
end

local function beginIslandRise(record): Model?
	if record.permanentlyDespawned or record.state == "Rising" or record.state == "Rendered" or record.state == "Sinking" then
		return record.model
	end

	local streamingConfig = getStreamingConfig()
	local maxRendered = streamingConfig.MaxRenderedIslands or 200
	if renderedRecordCount >= maxRendered then
		enforceRenderedLimit(1)
		if renderedRecordCount >= maxRendered then
			return nil
		end
	end

	local now = getNow()
	if record.cullCooldownUntil and now < record.cullCooldownUntil then
		return nil
	end
	if record.blockedUntil and now < record.blockedUntil then
		return nil
	end

	-- Re-check broadphase obstacles right before showing the island. Cached
	-- records are deterministic, but boats/props may have moved into the spot.
	if not isSpotClear(record.centerPos, record.radius, record, true) then
		record.blockedUntil = now + (streamingConfig.ObstacleRetryDelay or 20)
		return nil
	end

	local model = cloneRecordModel(record)
	if not model then
		return nil
	end

	record.state = "Rising"
	record.activatedAt = now
	record.expiresAt = now + (record.lifetime or getRecordLifetime(record))
	record.blockedUntil = nil
	markRendered(record)

	if not isRisingEnabled() then
		model:PivotTo(record.finalPivot)
		publishRisenIsland(record)
		return model
	end

	model.Parent = ensureRisingIslandFolder()
	model:PivotTo(record.hiddenPivot)
	model:SetAttribute("IslandRising", true)
	model:SetAttribute("IslandRisen", false)
	model:SetAttribute("IslandSinking", false)

	local riseConfig = getRiseConfig()
	playConfiguredSound(model, riseConfig, "IslandRisingSound")

	local tweenInfo = makeTweenInfo(riseConfig, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	tweenModelPivot(record, activeRiseTweens, tweenInfo, record.finalPivot, function()
		if record.state ~= "Rising" or not record.model or not record.model.Parent then
			return
		end
		record.model:PivotTo(record.finalPivot)
		publishRisenIsland(record)
	end)

	return model
end

-- Record generation ------------------------------------------------------------

local function cacheRecord(record)
	local key = record.key
	if key then
		cellCache[key] = record
	end
	table.insert(allGeneratedRecords, record)
	record.node = islandOctree:CreateNode(Vector3.new(record.centerPos.X, PLANE_Y, record.centerPos.Z), {
		radius = record.radius,
		record = record,
	})
	return record
end

local function makeRecord(template: Model, biomeName: string, centerPos: Vector3, yaw: number, radius: number, key: string?, cx: number?, cz: number?, rng: Random?)
	return {
		key = key,
		cx = cx,
		cz = cz,
		template = template,
		biomeName = biomeName,
		centerPos = Vector3.new(centerPos.X, PLANE_Y, centerPos.Z),
		yaw = yaw,
		radius = radius,
		state = "Cached",
		cacheCreatedAt = getNow(),
		lastTouched = getNow(),
		lifetime = getRecordLifetime({ cx = cx, cz = cz }, rng),
	}
end

local function generateCellRecord(cx: number, cz: number)
	local key = cellKey(cx, cz)
	if cellCache[key] ~= nil then
		return cellCache[key]
	end

	local now = getNow()
	local retryAt = blockedCellRetryAt[key]
	if retryAt and now < retryAt then
		return nil
	end

	local catalogList = IslandGenerator.GetCatalog()
	if #catalogList == 0 then
		return nil
	end

	local streamingConfig = getStreamingConfig()
	local pl = Config.Placement
	local cell = getCellSize()
	local rng = Random.new(getCellSeed(cx, cz))

	if rng:NextNumber() > (streamingConfig.IslandChance or 1) then
		cellCache[key] = NO_ISLAND
		return NO_ISLAND
	end

	local baseX, baseZ = cx * cell, cz * cell
	local jitter = pl.GridJitter or 0
	local x = baseX + rng:NextNumber(-cell * jitter, cell * jitter)
	local z = baseZ + rng:NextNumber(-cell * jitter, cell * jitter)
	local distOrigin = math.sqrt(x * x + z * z)

	if streamingConfig.RespectWorldRadius == true and distOrigin > pl.WorldRadius then
		cellCache[key] = NO_ISLAND
		return NO_ISLAND
	end
	if distOrigin < pl.SpawnSafetyRadius then
		cellCache[key] = NO_ISLAND
		return NO_ISLAND
	end

	local pos = Vector3.new(x, PLANE_Y, z)
	local entry = weightedPickEntry(catalogList, rng)
	local template = entry.templates[rng:NextInteger(1, #entry.templates)]
	local radius = modelRadius(template)

	-- Overlap failures are permanent for this deterministic cell. Obstacle
	-- failures are retried because boats/props may move later.
	if not isSpotClear(pos, radius, nil, false) then
		cellCache[key] = NO_ISLAND
		return NO_ISLAND
	end
	if hasBlockingObstacle(pos, radius) then
		blockedCellRetryAt[key] = now + (streamingConfig.ObstacleRetryDelay or 20)
		return nil
	end

	local yaw = rng:NextNumber(0, math.pi * 2)
	local record = makeRecord(template, entry.name, pos, yaw, radius, key, cx, cz, rng)
	cacheRecord(record)
	blockedCellRetryAt[key] = nil
	return record
end

-- Seeds the placement octree with any islands already present in workspace.Map at
-- startup (e.g. user-dropped anchors or a previous run) so dynamic generation
-- never overlaps them.
local function seedOctreeFromMap(map: Folder)
	for _, child in map:GetChildren() do
		if child:IsA("Model") and not recordsByModel[child] then
			local center = child:FindFirstChild(Config.CenterPartName)
			local pos: Vector3
			if center and center:IsA("BasePart") then
				pos = center.Position
			else
				pos = child:GetPivot().Position
			end
			local radius = modelRadius(child)
			islandOctree:CreateNode(Vector3.new(pos.X, PLANE_Y, pos.Z), {
				radius = radius,
				existing = true,
			})
		end
	end
	mapSeeded = true
end

-- Streaming loop ---------------------------------------------------------------

local function forEachPlayerCell(radius: number, maxCells: number, callback)
	local roots = getPlayerRoots()
	if #roots == 0 then
		return 0
	end

	local cell = getCellSize()
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
	local maxCells = streamingConfig.MaxCellsPerCycle or 384
	local cellsPerYield = streamingConfig.CellsPerYield or 32
	local processed = 0

	forEachPlayerCell(streamingConfig.GenerationRadius or Config.Placement.WorldRadius, maxCells, function(cx, cz)
		local key = cellKey(cx, cz)
		if cellCache[key] == nil then
			generateCellRecord(cx, cz)
		end
		processed += 1
		if processed % cellsPerYield == 0 then
			task.wait()
		end
	end)
end

local function activateRecordsAroundPlayers()
	local streamingConfig = getStreamingConfig()
	local maxActivations = streamingConfig.MaxActivationsPerCycle or 8
	local activationRadius = (getRiseConfig().TriggerDistance or 0) + Config.Placement.MaxIslandRadius + getCellSize()
	local activated = 0

	forEachPlayerCell(activationRadius, streamingConfig.MaxActivationCellsPerCycle or 256, function(_, _, key)
		if activated >= maxActivations then
			return false
		end

		local record = cellCache[key]
		if type(record) ~= "table" then
			return nil
		end

		record.lastTouched = getNow()
		if record.state == "Cached" and not record.permanentlyDespawned and isAnyPlayerCloseEnoughToRise(record) then
			local model = beginIslandRise(record)
			if model then
				activated += 1
				if activated >= maxActivations then
					return false
				end
			end
		end
		return nil
	end)
end

local function updateLifetimeDespawns()
	local now = getNow()
	local expiredRecords = {}
	for record, _ in activeRecords do
		if record.state ~= "Sinking" and record.expiresAt and now >= record.expiresAt then
			table.insert(expiredRecords, record)
		end
	end
	for _, record in expiredRecords do
		beginIslandSink(record, "Lifetime", true)
	end
end

-- Caps the cached cell records (ROADMAP 4.1). Only cells that are far from every
-- player and not rising/rendered are evicted, least-recently-touched first. An
-- evicted cell is generated again from its seed if a player returns. Cells within
-- 1.5x GenerationRadius are never evicted.
local function pruneCachedRecords()
	local streamingConfig = getStreamingConfig()
	local cap = streamingConfig.MaxCachedRecords or 3000
	local total = #allGeneratedRecords
	if total <= cap then
		return
	end

	local keepRadius = (streamingConfig.GenerationRadius or Config.Placement.WorldRadius) * 1.5
	local keepDistSq = keepRadius * keepRadius

	local candidates = {}
	for _, record in allGeneratedRecords do
		if
			record.key
			and record.state == "Cached"
			and record.model == nil
			and not record.permanentlyDespawned
			and distanceSqToNearestPlayer(record.centerPos) > keepDistSq
		then
			table.insert(candidates, record)
		end
	end
	table.sort(candidates, function(a, b)
		return (a.lastTouched or 0) < (b.lastTouched or 0)
	end)

	local count = math.min(total - cap, #candidates)
	local removed = {}
	for i = 1, count do
		local record = candidates[i]
		if cellCache[record.key] == record then
			cellCache[record.key] = nil
		end
		blockedCellRetryAt[record.key] = nil
		if record.node then
			islandOctree:RemoveNode(record.node)
			record.node = nil
		end
		removed[record] = true
	end
	if count > 0 then
		removeGeneratedRecords(removed)
	end
end

local function streamingStep()
	generateCellsAroundPlayers()
	activateRecordsAroundPlayers()
	updateLifetimeDespawns()
	enforceRenderedLimit(0)
	pruneCachedRecords()
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
		print("[IslandGenerator] dynamic island streaming started. Render cap: " .. tostring(streamingConfig.MaxRenderedIslands or 200))

		while generationToken == token do
			local ok, err = pcall(streamingStep)
			if not ok then
				warn("[IslandGenerator] streaming step failed: " .. tostring(err))
			end
			task.wait(getStreamingConfig().GenerationInterval or 1.25)
		end

		if generationToken == token then
			streamingLoopRunning = false
		end
	end)
end

-- Static one-shot fallback -----------------------------------------------------

local function generateStaticScatter()
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
				if distOrigin > pl.WorldRadius or distOrigin < pl.SpawnSafetyRadius then
					continue
				end

				local pos = Vector3.new(x, PLANE_Y, z)
				local entry = weightedPickEntry(catalogList, rng)
				local template = entry.templates[rng:NextInteger(1, #entry.templates)]
				local radius = modelRadius(template)

				if isSpotClear(pos, radius, nil, true) then
					local yaw = rng:NextNumber(0, math.pi * 2)
					local record = cacheRecord(makeRecord(template, entry.name, pos, yaw, radius, nil, gx, gz, rng))
					if beginIslandRise(record) then
						placed += 1
					end
					task.wait()
					break -- island placed for this cell
				end
				-- else: collided -> re-roll position/template (find a new spot).
				task.wait()
			end
		end
	end

	print("[IslandGenerator] static scatter complete: " .. placed .. " island(s) placed.")
end

-- Public API -------------------------------------------------------------------

-- Rebuilds and returns the biome catalog currently found under ServerStorage.
function IslandGenerator.GetCatalog()
	if catalog == nil then
		buildCatalog()
	end
	return catalog
end

-- Starts dynamic island streaming. The old one-shot scatter remains available by
-- setting IslandConfig.Streaming.Enabled = false, but the default path keeps
-- generating/caching cells around moving players for the whole server session.
function IslandGenerator.Generate()
	local catalogList = IslandGenerator.GetCatalog()
	if #catalogList == 0 then
		warn("[IslandGenerator] No premade islands found under ServerStorage." .. Config.PremadeIslandsRoot .. ".")
		return
	end

	local map = ensureMapFolder()
	if not mapSeeded then
		seedOctreeFromMap(map)
	end

	if isStreamingEnabled() then
		startStreamingLoop()
	else
		generateStaticScatter()
	end
end

-- Places a single random premade island at `centerPos`. Useful for dropping an
-- island at runtime (e.g. via a debug/admin tool). Returns the placed Model.
function IslandGenerator.PlaceOne(centerPos: Vector3, index: number): Model?
	local worldSeed = getWorldSeed()
	local rng = Random.new(worldSeed + (index or math.random(1, 100000)))

	local map = ensureMapFolder()
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
	local pos = Vector3.new(centerPos.X, PLANE_Y, centerPos.Z)
	if not isSpotClear(pos, radius, nil, true) then
		return nil
	end
	local yaw = rng:NextNumber(0, math.pi * 2)
	local record = cacheRecord(makeRecord(template, entry.name, pos, yaw, radius, nil, nil, nil, rng))
	return beginIslandRise(record)
end

function IslandGenerator.GetStats()
	local cachedRecords = #allGeneratedRecords
	return {
		CachedCells = cachedRecords,
		CachedRecords = cachedRecords,
		RenderedIslands = renderedRecordCount,
		MaxRenderedIslands = getStreamingConfig().MaxRenderedIslands or 200,
		Streaming = streamingLoopRunning,
	}
end

-- Removes every island this generator placed and resets placement/streaming
-- caches. Any user-dropped anchors present in workspace.Map are preserved (we
-- only destroy what we put there). Call this then Generate() to rebuild.
function IslandGenerator.ClearGenerated()
	generationToken += 1
	streamingLoopRunning = false

	local tweenRecords = {}
	for record, _ in activeRiseTweens do
		table.insert(tweenRecords, record)
	end
	for record, _ in activeSinkTweens do
		table.insert(tweenRecords, record)
	end
	for _, record in tweenRecords do
		cleanupPivotTween(activeRiseTweens, record)
		cleanupPivotTween(activeSinkTweens, record)
	end

	for _, record in allGeneratedRecords do
		local model = record.model
		if model then
			untagIsland(model)
			recordsByModel[model] = nil
			if model.Parent then
				model:Destroy()
			end
		end
	end

	table.clear(cellCache)
	table.clear(blockedCellRetryAt)
	table.clear(allGeneratedRecords)
	table.clear(activeRecords)
	table.clear(recordsByModel)
	table.clear(activeRiseTweens)
	table.clear(activeSinkTweens)
	renderedRecordCount = 0

	islandOctree:ClearAllNodes()
	mapSeeded = false
	catalog = nil -- force re-discovery on next Generate
end

return IslandGenerator
