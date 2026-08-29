--!nonstrict
--!optimize 2

--[[
	IslandConfig
	============
	Data-only tuning module for the island generator. There is NO logic here:
	every knob a user would want to tweak lives in this file and is read by
	IslandGenerator at generation time.

	Conventions:
		* Every weight is optional. A missing Weight falls back to DEFAULT_WEIGHT.
		  An explicit Weight of 0 removes the entry from its weighted pool; if a
		  pool ends up with a total weight of 0, the picker falls back to a
		  uniform random choice so generation never breaks.
		* Heights are expressed in studs ABOVE the water plane. The water plane
		  itself is Settings.GRID_SETTINGS.PLANE_OFFSET (Y = 25 by default) and is
		  mirrored here as PlaneOffset so nothing is hardcoded to 0.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Settings = require(ReplicatedStorage.Gerstner.Settings)

local IslandConfig = {}

-- Weight used whenever a category/structure omits `Weight`.
IslandConfig.DEFAULT_WEIGHT = 1

-- Water level the islands shorelines align to. Mirrored from the ocean
-- settings so changing PLANE_OFFSET in Gerstner/Settings moves island
-- shorelines with it automatically.
IslandConfig.PlaneOffset = Settings.GRID_SETTINGS.PLANE_OFFSET.Y

-- How deep (below the water plane) the shelf sits at the island rim, and how
-- far the closed "skirt" of the mesh extends down. The skirt must reach below
-- the ocean's DEPTH_RAY_LENGTH (15) so depth raycasts always hit land.
IslandConfig.ShelfDepth = 2.5
IslandConfig.SkirtDepth = 28

--==========================================================================
-- BIOME CATEGORIES
--==========================================================================
-- Each biome tints the generated terrain and owns a weighted structure pool.
--   Weight        : relative spawn weight (missing -> DEFAULT_WEIGHT)
--   Colors        : vertex palette (Sand at the shore, Grass inland, Rock on
--                   cliffs/peaks, Snow above SnowLine, Underwater shelf)
--   SnowLine      : fraction of MaxHeight above which snow appears (nil = none)
--   RockSteepness: terrain normal.Y below which the surface paints as rock
--   BeachHeight   : height (studs) of the sandy beach band above water
--   RockLine      : fraction of MaxHeight where bare rock starts taking over
--   Structures    : [structureId] = weight inside this biome's pool
--==========================================================================
IslandConfig.BiomeCategories = {
	Jungle = {
		Weight = 5,
		Colors = {
			Sand = Color3.fromRGB(226, 209, 164),
			Grass = Color3.fromRGB(86, 142, 66),
			Rock = Color3.fromRGB(108, 110, 102),
			Snow = nil,
			Underwater = Color3.fromRGB(84, 110, 86),
		},
		SnowLine = nil,
		RockSteepness = 0.72,
		BeachHeight = 2.6,
		RockLine = 0.62,
		Structures = {
			Shipwreck = 3,
			Ruins = 2,
			Dock = 4,
			Barrel = 3,
			Crate = 3,
			Buoy = 1,
			Debris = 2,
		},
	},

	Snow = {
		Weight = 3,
		Colors = {
			Sand = Color3.fromRGB(198, 203, 208),
			Grass = Color3.fromRGB(148, 166, 152),
			Rock = Color3.fromRGB(92, 98, 108),
			Snow = Color3.fromRGB(238, 243, 249),
			Underwater = Color3.fromRGB(72, 92, 108),
		},
		SnowLine = 0.45,
		RockSteepness = 0.7,
		BeachHeight = 2.0,
		RockLine = 0.55,
		Structures = {
			Shipwreck = 4,
			Ruins = 2,
			Dock = 2,
			Barrel = 2,
			Crate = 2,
			Buoy = 2,
			Debris = 3,
		},
	},

	Desert = {
		Weight = 3,
		Colors = {
			Sand = Color3.fromRGB(224, 197, 142),
			Grass = Color3.fromRGB(196, 172, 112),
			Rock = Color3.fromRGB(150, 106, 78),
			Snow = nil,
			Underwater = Color3.fromRGB(122, 108, 80),
		},
		SnowLine = nil,
		RockSteepness = 0.74,
		BeachHeight = 3.2,
		RockLine = 0.66,
		Structures = {
			Shipwreck = 3,
			Ruins = 3,
			Dock = 2,
			Barrel = 2,
			Crate = 2,
			Buoy = 1,
			Debris = 3,
		},
	},
}

--==========================================================================
-- ISLAND TYPE CATEGORIES
--==========================================================================
-- Controls island footprint + silhouette.
--   Kind      : "Island" (normal), "Atoll" (ring + lagoon)
--   RadiusMin/Max: range (studs) a procedural radius is rolled in
--   MaxHeight : peak terrain height above the water plane
--   Resolution: optional mesh-grid override (see Generation.MeshSpacing)
--==========================================================================
IslandConfig.TypeCategories = {
	Islet = {
		Weight = 5,
		Kind = "Island",
		RadiusMin = 45,
		RadiusMax = 85,
		MaxHeight = 13,
	},
	Atoll = {
		Weight = 2,
		Kind = "Atoll",
		RadiusMin = 95,
		RadiusMax = 135,
		MaxHeight = 7,
	},
	Mainland = {
		Weight = 1,
		Kind = "Island",
		RadiusMin = 150,
		RadiusMax = 220,
		MaxHeight = 36,
	},
}

--==========================================================================
-- STRUCTURE DEFINITIONS
--==========================================================================
-- Mode     : "Anchored" (fixed, explorable) or "Floating" (bobs on waves)
-- Category : "Land" (raycasts down onto the island) or "Water" (shore/sea)
-- Footprint: radius in studs used for overlap checks
-- MinRadius/MaxRadius: island radius range the structure can spawn on
-- AboveWater/Draft : for Anchored water structures - how much sits above /
--                    below the water plane
-- RideHeight: for Floating objects - target offset of the root above a wave
--==========================================================================
IslandConfig.StructureDefinitions = {
	Shipwreck = {
		Weight = 3,
		Mode = "Anchored",
		Category = "Water",
		Footprint = 14,
		MinRadius = 55,
		MaxRadius = math.huge,
		AboveWater = 3.5,
		Draft = 2.5,
		Color = Color3.fromRGB(74, 55, 38),
		Material = Enum.Material.Wood,
	},

	Ruins = {
		Weight = 2,
		Mode = "Anchored",
		Category = "Land",
		Footprint = 10,
		MinRadius = 40,
		MaxRadius = math.huge,
		AboveWater = 0,
		Draft = 0,
		Color = Color3.fromRGB(150, 150, 144),
		Material = Enum.Material.Slate,
	},

	Dock = {
		Weight = 4,
		Mode = "Anchored",
		Category = "Water",
		Footprint = 12,
		MinRadius = 45,
		MaxRadius = math.huge,
		AboveWater = 1.0, -- deck height above the water plane
		Draft = 7, -- post length below the deck
		Color = Color3.fromRGB(112, 84, 54),
		Material = Enum.Material.WoodPlanks,
	},

	-- -- -- -- -- Floating debris -- -- -- -- --
	Barrel = {
		Weight = 3,
		Mode = "Floating",
		Category = "Water",
		Footprint = 3,
		MinRadius = 0,
		MaxRadius = math.huge,
		RideHeight = 0.4,
		Color = Color3.fromRGB(96, 70, 42),
		Material = Enum.Material.Wood,
	},
	Crate = {
		Weight = 3,
		Mode = "Floating",
		Category = "Water",
		Footprint = 3,
		MinRadius = 0,
		MaxRadius = math.huge,
		RideHeight = 0.5,
		Color = Color3.fromRGB(134, 98, 58),
		Material = Enum.Material.WoodPlanks,
	},
	Buoy = {
		Weight = 1,
		Mode = "Floating",
		Category = "Water",
		Footprint = 3,
		MinRadius = 0,
		MaxRadius = math.huge,
		RideHeight = 0.6,
		Color = Color3.fromRGB(196, 64, 48),
		Material = Enum.Material.Plastic,
	},
	Debris = {
		Weight = 2,
		Mode = "Floating",
		Category = "Water",
		Footprint = 4,
		MinRadius = 0,
		MaxRadius = math.huge,
		RideHeight = 0.25,
		Color = Color3.fromRGB(104, 82, 56),
		Material = Enum.Material.Wood,
	},
}

--==========================================================================
-- PLACEMENT
--==========================================================================
IslandConfig.Placement = {
	GenerateProcedural = true, -- fill the world with islands if no/ few anchors
	WorldRadius = 2600, -- islands are scattered within this radius of origin
	CellSize = 360, -- jittered-grid spacing for procedural placement
	GridJitter = 0.45, -- random offset per cell, as a fraction of CellSize
	SpawnSafetyRadius = 320, -- keep this radius around world origin island-free
	SpacingPadding = 70, -- extra gap added to (rA + rB) between islands
	MaxPlacementAttempts = 14, -- placement tries per island before giving up

	MaxStructuresPerIsland = 4, -- anchored structures (wreck/ruins/dock)
	MaxFloatingObjectsPerIsland = 3, -- floating debris per island
	MaxFloatingObjectsTotal = 48, -- hard global cap for Heartbeat performance

	StructuresOverlapPadding = 4, -- extra studs between structure footprints
	StructureGroundEmbed = 0.6, -- how far land structures sink into the ground
}

--==========================================================================
-- GENERATION / MESH
--==========================================================================
IslandConfig.Generation = {
	-- Vertex spacing target (studs). Grid resolution is derived per island from
	-- its diameter, then clamped to Min/MaxResolution. Smaller spacing =
	-- smoother terrain = more triangles.
	MeshSpacing = 8,
	MinResolution = 28,
	MaxResolution = 72,

	-- fBm noise octaves for the heightmap.
	NoiseOctaves = 4,

	-- Batching: how many islands to build per yielded batch, and how many mesh
	-- vertices/attributes to push between task.wait()s, so a huge world never
	-- freezes the server for a frame.
	IslandsPerBatch = 1,
	VertexBudgetPerFrame = 500,

	-- Collision fidelity for the terrain MeshPart. PreciseConvexDecomposition
	-- gives walkable concave hills; the generator retries with Default on
	-- failure, and finally falls back to a plain Part if mesh creation fails.
	CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition,

	-- SmoothPlastic renders vertex colors cleanly. Terrain is vertex-colored.
	TerrainMaterial = Enum.Material.SmoothPlastic,

	-- Cheap LOD: islands farther than LOD.Distance from origin use a coarser
	-- mesh (resolution * LOD.ResolutionFactor). Deterministic, purely visual.
	LOD = {
		Distance = 1900,
		ResolutionFactor = 0.65,
	},
}

--==========================================================================
-- FLOATING OBJECTS
--==========================================================================
IslandConfig.Floating = {
	-- Anchored bob is the default (stable, cheap, can never drift into boats).
	-- EnablePhysics = true switches to unanchored parts driven by a VectorForce
	-- spring + AlignOrientation. It looks the same but lets small objects nudge.
	EnablePhysics = false,

	-- Anchored-bob debris does not collide (so it can never block boats or
	-- players). Physics mode forces CanCollide = true so objects can beach.
	CanCollide = false,

	-- Heartbeat cost control: BoatManager buoyancy is sampled for this many
	-- floating objects per frame (round-robin). 8 objects/frame keeps the
	-- amortized cost negligible even at the global cap.
	UpdatesPerFrame = 8,

	-- Physics-mode spring tuning (mass-normalized). Position spring k/d for Y
	-- (hovering on the wave) and XZ (leash back to spawn point).
	SpringK = 28,
	SpringD = 9,
	LeashK = 6,
	LeashD = 4,
	MaxForce = 120000,
}

return IslandConfig
