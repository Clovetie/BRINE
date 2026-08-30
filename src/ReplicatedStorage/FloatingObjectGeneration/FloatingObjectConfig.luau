--!nonstrict
--!optimize 2

--[[
	FloatingObjectConfig
	====================
	Data-only tuning module for the UNANCHORED floating structure/object
	streamer. Mirrors IslandConfig in shape so the two systems feel identical
	to configure.

	There is NO geometry code here. Floating objects are authored by hand as
	Models (or single BaseParts) inside ServerStorage.FloatingObjects. The
	generator discovers those templates, reads their SIZE TAG, caches
	deterministic records around moving players, and clones/renders records
	only while a player can actually see them.

	Template contract (see FLOATING_OBJECTS.md):
		* The template lives anywhere under ServerStorage.FloatingObjects
		  (folders may nest to any depth; recursion does not descend into a
		  Model, so sub-models are treated as components, not templates).
		* Size class comes from a CollectionService tag on the template:
		    "Small", "Medium", "Large" or "Debris".
		  A template with several of those tags uses the FIRST match in
		  Config.ClassTags order. Untagged templates are skipped (warned once).
		* Multi-part templates do not need welds: every BasePart is welded to
		  the hull with a WeldConstraint at clone time. Every BasePart is
		  unanchored at clone time (these are UNANCHORED objects).
		* Optional per-template attribute overrides (set on the template):
		    Weight      number  - rarity weight inside its class pool
		    FloatRatio  number  - 0..1, fraction of the object's height that
		                          rides ABOVE the waterline (0.5 = half sunk)
		    SimDistance number  - per-object LOD override (studs)

	Conventions:
		* Every weight is optional. A missing weight falls back to
		  DEFAULT_WEIGHT. A weight <= 0 removes the entry from its pool; if a
		  pool ends up empty the picker falls back to a uniform random choice
		  so generation never breaks.
		* Vertical placement is relative to the water plane, mirrored from
		  Settings.GRID_SETTINGS.PLANE_OFFSET.Y (25 by default), identical to
		  the island generator.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Settings = require(ReplicatedStorage.Gerstner.Settings)

local FloatingObjectConfig = {}

-- Weight used whenever a class/template omits a weight.
FloatingObjectConfig.DEFAULT_WEIGHT = 1

-- Water level the objects float on. Mirrored from the ocean settings so
-- changing PLANE_OFFSET moves floating objects with it automatically.
-- Scripting docs: https://create.roblox.com/docs/scripting
FloatingObjectConfig.PlaneOffset = Settings.GRID_SETTINGS.PLANE_OFFSET.Y

-- The ServerStorage folder that holds every premade floating object
-- template. ServerStorage does not replicate to clients, so templates never
-- reach players until the server clones them into Workspace.
-- https://create.roblox.com/docs/reference/engine/classes/ServerStorage
FloatingObjectConfig.TemplatesRoot = "FloatingObjects"

-- Tag applied to every RENDERED clone so other systems (or a debugger) can
-- find generated floating objects with CollectionService:GetTagged().
-- Deliberately NOT "Island" - ZoneManager must never index these.
FloatingObjectConfig.ObjectTag = "FloatingObject"

-- Ordered size-tag -> class mapping. The FIRST matching tag wins when a
-- template carries several size tags. Order = priority.
FloatingObjectConfig.ClassTags = {
	{ Tag = "Small", Class = "Small" },
	{ Tag = "Medium", Class = "Medium" },
	{ Tag = "Large", Class = "Large" },
	{ Tag = "Debris", Class = "Debris" },
}

-- Per-class tuning. Any key may be omitted; safe defaults are applied by the
-- generator (see FloatingObjectConfig.DefaultClassSettings below).
FloatingObjectConfig.Classes = {
	-- Small props: crates, barrels, rowboats.
	Small = {
		Weight = 3,
		PerCellMin = 1, -- objects generated in one cell
		PerCellMax = 2,
		ClusterRadius = 26, -- max offset from the cell's jittered center
		MinSpacing = 12, -- min center distance to other floating records
		SimDistance = 210, -- within this player distance: full buoyancy sim
		FloatRatio = 0.5, -- half the height above water
	},
	-- Medium structures: rafts, dinghies, broken masts.
	Medium = {
		Weight = 2,
		PerCellMin = 1,
		PerCellMax = 1,
		ClusterRadius = 14,
		MinSpacing = 26,
		SimDistance = 250,
		FloatRatio = 0.5,
	},
	-- Large structures: wrecks, floating docks, ruined hulls.
	Large = {
		Weight = 1,
		PerCellMin = 1,
		PerCellMax = 1,
		ClusterRadius = 6,
		MinSpacing = 48,
		SimDistance = 300,
		FloatRatio = 0.35, -- rides low in the water
	},
	-- Debris: planks, flotsam, jetsam. Spawned in clusters.
	Debris = {
		Weight = 4,
		PerCellMin = 2,
		PerCellMax = 5,
		ClusterRadius = 34,
		MinSpacing = 6,
		SimDistance = 170,
		FloatRatio = 0.4,
	},
}

-- Fallbacks merged into every Classes entry that omits a field.
FloatingObjectConfig.DefaultClassSettings = {
	Weight = 1,
	PerCellMin = 1,
	PerCellMax = 1,
	ClusterRadius = 12,
	MinSpacing = 10,
	SimDistance = 200,
	FloatRatio = 0.5,
}

--==========================================================================
-- PLACEMENT
--==========================================================================
FloatingObjectConfig.Placement = {
	-- Jittered-grid cell size for floating object records. Smaller than the
	-- island CellSize (360) because floating objects are small and dense.
	CellSize = 150,

	-- Random offset per cell, as a fraction of CellSize.
	GridJitter = 0.4,

	-- Chance that an otherwise valid cell contains floating objects at all.
	ObjectChance = 0.65,

	-- Keep this radius around world origin object-free (spawn safety).
	SpawnSafetyRadius = 140,

	-- How many position re-rolls each object gets inside its cell before the
	-- object is skipped.
	MaxPlacementAttempts = 6,

	-- Extra margin added around an object's footprint when querying
	-- workspace parts (boats, docks...) so a spot that merely grazes one is
	-- rejected. Player characters are excluded from this broadphase check.
	ObstaclePadding = 2,

	-- Extra clearance kept between an object center and an island footprint
	-- (ZoneManager's island octree) so objects never generate beached.
	IslandAvoidPadding = 24,

	-- Estimate of the largest floating-object spacing radius, used to widen
	-- the record-octree overlap search so a big neighbour is never missed.
	MaxSpacingRadius = 48,

	-- Estimate of the largest possible island radius (mirrors
	-- IslandConfig.Placement.MaxIslandRadius), used to widen the island
	-- octree overlap search.
	MaxIslandRadius = 400,

	-- Legacy boundary. Only used when Streaming.RespectWorldRadius is true.
	WorldRadius = 2600,
	RespectWorldRadius = false,
}

--==========================================================================
-- DYNAMIC STREAMING / CACHE ("looking at them")
--==========================================================================
FloatingObjectConfig.Streaming = {
	-- Keep evaluating cells around moving players for the whole server
	-- session. Records are cached as lightweight Lua data; actual clones are
	-- created only while a player can see them, then cached again.
	Enabled = true,

	-- How far from each player cells are generated/cached.
	GenerationRadius = 1700,

	-- Background-loop pacing. Work is capped/yielded per cycle.
	GenerationInterval = 1.25,
	MaxCellsPerCycle = 256,
	CellsPerYield = 48,
	MaxActivationCellsPerCycle = 320,
	MaxSpawnsPerCycle = 24,
	MaxCachesPerCycle = 64,

	-- HARD render budget: at most 500 unanchored floating objects exist in
	-- Workspace at once. When the cap is reached, objects with NO player
	-- nearby are cached first, then the OLDEST rendered objects.
	MaxRenderedObjects = 500,

	-- Beyond this player distance a rendered object is cached immediately
	-- (nobody can see it). Should be >= the largest class SimDistance.
	CacheDistance = 650,

	-- A rendered object that is close enough to see but is NOT inside any
	-- player's camera view cone is cached after this many seconds of being
	-- unseen (prevents popping while a player turns around).
	OutOfViewGrace = 3,

	-- Cooldown before a cached record may re-render (anti-thrash).
	RespawnCooldown = 1.5,

	-- If a boat/prop blocks a deterministic candidate, retry the cell later
	-- instead of permanently burning it.
	ObstacleRetryDelay = 25,

	-- Camera interest settings. Clients report their camera position + look
	-- direction through the CameraReport RemoteEvent; stale reports older
	-- than CameraDataTimeout fall back to distance-only interest.
	CameraMaxDistance = 800,
	CameraViewConeAngleDeg = 55, -- half-angle; 55 deg ~= 110 deg cone
	CameraDataTimeout = 3,
	CameraMinReportInterval = 0.15, -- server-side rate limit per player

	-- Idle cache hygiene. Cells untouched for CellIdleLifetime that no
	-- player is near are dropped from the cache; they re-evaluate
	-- deterministically (same seed) when a player returns.
	CacheTrimInterval = 90,
	CellIdleLifetime = 600,
	CacheTrimMargin = 256,
}

--==========================================================================
-- BUOYANCY / PHYSICS LOD
--==========================================================================
FloatingObjectConfig.Buoyancy = {
	-- When true, near players the objects are UNANCHORED, server-owned
	-- assemblies driven by AlignPosition/AlignOrientation (the same modern
	-- constraint pattern the ship singleton uses). When false, every
	-- rendered object is an anchored static prop at the waterline.
	Enabled = true,

	-- HeightLookup method: "FAST" (approximate Gerstner formula, cheapest)
	-- or "PRECISE" (triangle interpolation). Both work on the server.
	LookupMethod = "FAST",

	-- Each buoyant object's target is refreshed on a staggered clock every
	-- UpdateInterval seconds. AlignPosition/AlignOrientation interpolate
	-- between refreshes, so 8-12 Hz looks smooth at a fraction of the cost.
	UpdateInterval = 0.12,
	MaxTargetUpdatesPerFrame = 60,

	-- Wave zone multipliers (island/whirlpool damping) are re-read at most
	-- this often per object; ZoneManager:GetZoneParameters is comparatively
	-- expensive so it must not run every frame.
	ZoneRefreshInterval = 3,

	-- AlignPosition force cap = AssemblyMass * workspace.Gravity * this.
	ForceMultiplier = 5,
	MaxVelocity = 25,
	Responsiveness = 14,

	-- AlignOrientation torque cap = AssemblyMass * this (matches the ship's
	-- `Main.AssemblyMass * 5000` pattern).
	TorqueMultiplier = 5000,
	MaxAngularVelocity = 6,
	AngularResponsiveness = 10,

	-- Objects whose bounding-box XZ extent is below this use a cheap
	-- single-point bob (1 height lookup) instead of the 4-point
	-- BoatManager.CalculateBuoyancy sampling (4 lookups).
	SmallObjectExtent = 6,

	-- An object that sinks this far below the water plane is considered lost
	-- to physics (squeezed through the world) and permanently despawned.
	KillDepth = 160,
}

--==========================================================================
-- DESPAWN
--==========================================================================
FloatingObjectConfig.Despawn = {
	-- A rendered object lives for a deterministic random lifetime in this
	-- range before permanently despawning for the current server session.
	MinLifetime = 30 * 60,
	MaxLifetime = 45 * 60,

	-- Render-cap culls prefer objects with NO player inside
	-- (record spacing + this) distance. If every rendered object is
	-- protected, the OLDEST one is culled instead.
	CullNearPlayerDistance = 260,

	-- After a render-cap cull, the record waits this long before it may
	-- re-render (prevents an instant respawn/despawn loop at the cap).
	CullCooldown = 30,
}

return FloatingObjectConfig
