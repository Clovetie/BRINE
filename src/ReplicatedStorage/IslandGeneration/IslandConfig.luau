--!nonstrict
--!optimize 2

--[[
	IslandConfig
	============
	Data-only tuning module for the PREMADE island placement system.

	There is NO geometry, noise or mesh code here. Islands are authored by hand
	as complete Models inside ServerStorage.Islands; this module only tunes how
	the generator discovers, picks, scatters, and proximity-rises those premade
	templates into the world.

	Expected hierarchy (arbitrary nesting is supported):

		ServerStorage
		└── Islands                    (Config.PremadeIslandsRoot)
		    ├── Jungle                 (biome folder)
		    │   ├── Islet/…/MyIsland   (island Models, any folder depth)
		    │   └── IslandA            (a premade island Model)
		    ├── Snow                   (another biome folder)
		    └── LooseIsland            (a Model directly under the root —
		                                 assigned Config.DefaultBiome)

	Each premade island must satisfy the contract the ocean already relies on
	(see ZoneManager / Helper):

		Island (Model) — PrimaryPart = Center
		├── Center   BasePart (Config.CenterPartName) — the node anchor; its
		│            Position is the island center and its Y is the waterline.
		└── Radius   IntValue (Config.RadiusValueName) — island radius in studs.

	If a premade island is missing Center/Radius, the generator creates/derives
	them (Center at the model's bounding-box center, Radius from the bounding
	box, then Config.DefaultRadius).

	Conventions:
		* Every weight is optional. A missing Weight falls back to DEFAULT_WEIGHT.
		  An explicit Weight of 0 removes the entry from its weighted pool; if a
		  pool ends up with a total weight of 0, the picker falls back to a
		  uniform random choice so generation never breaks.
		* All final vertical placement is relative to the water plane, mirrored
		  from Settings.GRID_SETTINGS.PLANE_OFFSET.Y (25 by default). Streaming
		  caches generated cell records as players move; Rising/Despawn settings
		  control the up/down TweenService animations around those cached records.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Settings = require(ReplicatedStorage.Gerstner.Settings)

local IslandConfig = {}

-- Weight used whenever a biome/template omits `Weight`.
IslandConfig.DEFAULT_WEIGHT = 1

-- Water level the islands' shorelines align to. Mirrored from the ocean
-- settings (ReplicatedStorage.Gerstner.Settings.GRID_SETTINGS.PLANE_OFFSET.Y)
-- so changing PLANE_OFFSET moves premade islands with it automatically.
-- Scripting docs: https://create.roblox.com/docs/scripting
IslandConfig.PlaneOffset = Settings.GRID_SETTINGS.PLANE_OFFSET.Y

-- The ServerStorage folder that holds every premade island. ServerStorage is
-- NOT replicated to clients, so templates never reach the player until the
-- server clones them into workspace. See:
-- https://create.roblox.com/docs/reference/engine/classes/ServerStorage
IslandConfig.PremadeIslandsRoot = "Islands"

-- Optional per-biome weight override. Biomes are auto-discovered as subfolders
-- inside ServerStorage.<PremadeIslandsRoot>. If a folder's name has an entry
-- here that weight is used; otherwise the entry falls back to DEFAULT_WEIGHT.
-- A weight <= 0 excludes that biome folder from generation.
IslandConfig.BiomeWeights = {
	-- Jungle = 5,
	-- Snow   = 2,
	-- Desert = 1,
}

-- Biome label applied to Models that sit directly under the root (i.e. not
-- inside any biome folder). Handles the "loose island" edge case.
IslandConfig.DefaultBiome = "General"

-- Fallback radius used when a premade island has no Radius IntValue and its
-- bounding box has no XZ extent.
IslandConfig.DefaultRadius = 70

-- Names of the contract parts inside a premade island Model.
IslandConfig.CenterPartName = "Center"
IslandConfig.RadiusValueName = "Radius"

-- Size/anchoring for a Center part the generator creates when a template has
-- none. Kept as a 1x1x1 anchored, non-collidable part to match the contract.
IslandConfig.CenterPartSize = Vector3.new(1, 1, 1)

--==========================================================================
-- PLACEMENT / SCATTER
--==========================================================================
IslandConfig.Placement = {
	-- Scatter/cache islands on cells out from each moving player. WorldRadius is
	-- only used by the static fallback or when Streaming.RespectWorldRadius is
	-- true.
	WorldRadius = 2600,

	-- Jittered-grid cell size; candidate positions are generated on this grid.
	CellSize = 360,

	-- Random offset per cell, as a fraction of CellSize. Makes the grid look
	-- organic instead of a rigid lattice.
	GridJitter = 0.45,

	-- Keep this radius around world origin island-free (spawn safety).
	SpawnSafetyRadius = 320,

	-- Extra gap added to (rA + rB) between island centers (island overlap pad).
	SpacingPadding = 70,

	-- How many times per grid cell the static fallback re-rolls position +
	-- template before giving up on that cell.
	MaxPlacementAttempts = 16,

	-- Extra margin added around an island footprint when querying workspace
	-- parts, so a spot that merely grazes a boat/prop/baseplate is rejected.
	-- Player characters are excluded from this broadphase check so a moving
	-- player does not permanently block a deterministic cached cell.
	ObstaclePadding = 8,

	-- Octree overlap search reach (ROADMAP 4.2). Footprints up to this radius are
	-- found by the octree; wider ones are checked directly, so no neighbour is
	-- missed (premade islands can declare Radius above this value).
	MaxIslandRadius = 400,

	-- Anchor every BasePart of a placed island. Premade islands are authored in
	-- Studio and may not be anchored; unanchored parts would fall out of the
	-- world when cloned into Workspace. Turn this off only if a template relies
	-- on physics/motion.
	AnchorPlacedIslands = true,
}

--==========================================================================
-- DYNAMIC STREAMING / CACHE
--==========================================================================
IslandConfig.Streaming = {
	-- Keep evaluating cells around moving players for the whole server session.
	-- Generated cells are cached as lightweight records; actual island Models are
	-- cloned only when a player is close enough to trigger Rising.
	Enabled = true,

	-- How far from each player cells are generated/cached. The cache may grow
	-- beyond the rendered cap as players travel.
	GenerationRadius = 2600,

	-- Optional override. If nil, Placement.CellSize is used.
	-- CellSize = 360,

	-- Chance that an otherwise valid cell will contain an island.
	IslandChance = 1,

	-- Background-loop pacing. Work is capped/yielded so generation does not spike
	-- frame time when many cells are discovered at once.
	GenerationInterval = 1.25,
	MaxCellsPerCycle = 384,
	CellsPerYield = 32,
	MaxActivationCellsPerCycle = 256,
	MaxActivationsPerCycle = 8,

	-- Hard render/replication budget. The cached total can overflow this; the
	-- amount actually in Workspace is kept at or below this cap except while a
	-- near-player sink animation is finishing.
	MaxRenderedIslands = 200,

	-- Cap on cached cell records (ROADMAP 4.1). Only far, never-risen cells are
	-- evicted; a returning player regenerates them from the same seed.
	MaxCachedRecords = 3000,

	-- If a boat/prop/baseplate blocks a deterministic candidate, retry later
	-- instead of permanently burning that cell.
	ObstacleRetryDelay = 20,

	-- Leave false for endless ocean streaming. Turn true to keep the legacy
	-- WorldRadius boundary.
	RespectWorldRadius = false,
}

--==========================================================================
-- ISLAND RISING
--==========================================================================
IslandConfig.Rising = {
	-- When true, generated islands appear by rising out of the ocean once a
	-- player gets close enough. Turn this off to publish them immediately when
	-- activated.
	Enabled = true,

	-- Distance, in studs, from the island EDGE that starts the rise. The actual
	-- center-distance check is island Radius + TriggerDistance, so larger
	-- islands wake up before a player reaches their shoreline.
	TriggerDistance = 220,

	-- How far below the final waterline/pivot the island starts before tweening
	-- up into place.
	HiddenDepth = 90,

	-- TweenService animation settings for the rise.
	TweenTime = 4,
	EasingStyle = Enum.EasingStyle.Quad,
	EasingDirection = Enum.EasingDirection.Out,

	-- Placeholder rise SFX. Replace the zero with your uploaded sound id.
	SoundId = "rbxassetid://0",
	SoundVolume = 0.8,
	SoundRollOffMaxDistance = 500,
	SoundCleanupDelay = 12,
}

--==========================================================================
-- ISLAND DESPAWN / SINKING
--==========================================================================
IslandConfig.Despawn = {
	-- A rendered island lives for a deterministic random lifetime in this range
	-- before permanently despawning for the current server session.
	MinLifetime = 35 * 60,
	MaxLifetime = 60 * 60,

	-- If a despawning island is within Radius + NearPlayerDistance of any player,
	-- it visibly sinks first. Far-away islands are removed immediately to save
	-- replication and server work.
	NearPlayerDistance = 300,
	CullNearPlayerDistance = 500,

	-- Render-cap culls are not permanent; this cooldown prevents an island that
	-- was just culled from instantly re-rising while the player is still nearby.
	CullCooldown = 120,

	-- TweenService animation settings for sinking.
	SinkDepth = 90,
	TweenTime = 4,
	EasingStyle = Enum.EasingStyle.Quad,
	EasingDirection = Enum.EasingDirection.In,

	-- Placeholder sink SFX. Replace the zero with your uploaded sound id.
	SoundId = "rbxassetid://0",
	SoundVolume = 0.8,
	SoundRollOffMaxDistance = 500,
	SoundCleanupDelay = 12,
}

return IslandConfig
