--!nonstrict
--!optimize 2

--[[
	IslandConfig
	============
	Data-only tuning module for the PREMADE island placement system.

	There is NO geometry, noise or mesh code here. Islands are authored by hand
	as complete Models inside ServerStorage.Islands; this module only tunes how
	the generator discovers, picks and scatters those premade templates into the
	world.

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
		* All vertical placement is relative to the water plane, mirrored from
		  Settings.GRID_SETTINGS.PLANE_OFFSET.Y (25 by default).
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
	-- Scatter islands within this radius of the world origin.
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

	-- How many times per grid cell the generator re-rolls position + template
	-- before giving up on that cell, so a colliding spot becomes a new spot
	-- rather than an overlapping island.
	MaxPlacementAttempts = 16,

	-- Extra margin added around an island footprint when querying workspace
	-- parts, so a spot that merely grazes a boat/player/prop is rejected.
	ObstaclePadding = 8,

	-- Estimate of the largest possible premade island radius, used to widen the
	-- octree overlap search so a big neighbour is never missed.
	MaxIslandRadius = 400,

	-- Anchor every BasePart of a placed island. Premade islands are authored in
	-- Studio and may not be anchored; unanchored parts would fall out of the
	-- world when cloned into Workspace. Turn this off only if a template relies
	-- on physics/motion.
	AnchorPlacedIslands = true,
}

return IslandConfig
