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
		-- Fraction of the prop's own height riding above the waterline. Raised from
		-- 0.6 on the user's report that Small and Medium float too low. The knob only
		-- became trustworthy with the bounding-box seating fix in
		-- FloatingObjectGenerator.spawnRecord: before it, each template rode off its
		-- ratio by the model's pivot offset (Small measured 0.847 when asking 0.6).
		FloatRatio = 0.7,
	},
	-- Medium structures: rafts, dinghies, broken masts.
	Medium = {
		Weight = 2,
		PerCellMin = 1,
		PerCellMax = 1,
		ClusterRadius = 14,
		MinSpacing = 26,
		SimDistance = 250,
		FloatRatio = 0.7, -- raised from 0.6 with Small; measured 0.502 when asking 0.6
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
		PerCellMin = 1,
		PerCellMax = 3,
		ClusterRadius = 34,
		MinSpacing = 12,
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
	CellSize = 200,

	-- Random offset per cell, as a fraction of CellSize.
	GridJitter = 0.5,

	-- Chance that an otherwise valid cell contains floating objects at all. 1 =
	-- no extra thinning; the archipelago density field below does the thinning.
	ObjectChance = 1,

	-- ROADMAP 7.1: objects follow the same density field as the islands
	-- (IslandConfig.Placement.Density), so debris gathers near archipelagos and
	-- thins out over open water.
	Density = {
		Enabled = true,
		Scale = 1400,
		MinChance = 0.06,
		MaxChance = 0.45,
	},

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

	-- How far from each player cells are generated/cached. Islands use 2600;
	-- objects sit a bit closer so the sea is not overrun.
	GenerationRadius = 2200,

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
	CacheDistance = 900,

	-- No object renders within this distance of a player. Objects in that ring
	-- stay cached and appear once the player moves farther away. This keeps the
	-- area right around a boat clear of debris.
	MinPlayerDistance = 200,

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
	CameraMaxDistance = 900,
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
-- BUOYANCY / PHYSICS LOD  (ship-parity movement - see WaveFloat.luau)
--==========================================================================
-- Everything in this block exists to make a streamed prop ride the ocean the
-- way `Workspace.singletons.Ship.Client` rides it: four surface samples taken
-- at real Attachments on the hull, the ship's own drag/airborne model, and an
-- AlignPosition/AlignOrientation pair updated at the ship's cadence and gains.
FloatingObjectConfig.Buoyancy = {
	-- When true, near players the objects are UNANCHORED assemblies driven by
	-- AlignPosition/AlignOrientation (the same modern constraint pattern the
	-- ship singleton uses). When false, every rendered object is an anchored
	-- static prop at the waterline.
	Enabled = true,

	-- Where the surface height comes from.
	--   "ANALYTIC" (default) the Gerstner wave sum itself: cheap, continuous,
	--                        works on the server and on clients with no
	--                        EditableMesh/HeightLookup.ClientInit, and applies
	--                        the whirlpool dip (HeightLookup only does that in
	--                        its PRECISE branch).
	--   "MESH"               HeightLookup.Lookup per sample - literally what
	--                        the ship client does. Triangle-exact to the
	--                        rendered water, but 4 grid searches per object per
	--                        refresh; use it for hulls close to a player.
	HeightSource = "ANALYTIC",

	-- Only read by the "MESH" source. "PRECISE" = triangle interpolation
	-- (what the ship uses). "FAST" = the folded-|sin| approximation, which
	-- bobs objects to a DIFFERENT waveform than the mesh renders - it is here
	-- as an emergency budget knob, not as a default.
	LookupMethod = "PRECISE",

	-- Refresh cadence. Objects inside `NearDistance` of a player are the ones
	-- whose waterline you can actually see, so they get the ship's per-frame
	-- treatment; everything else stays on the staggered clock and is budgeted
	-- per frame so a full 500-object scene cannot spike the server.
	UpdateInterval = 0.12,
	NearUpdateInterval = 0,
	NearDistance = 150,
	NearExitRatio = 1.3, -- hysteresis: leave the near band past 150 * 1.3
	MaxTargetUpdatesPerFrame = 48,
	NearMaxTargetUpdatesPerFrame = 24,

	-- Wave zone multipliers (island/whirlpool damping) are re-read at most this
	-- often per object; ZoneManager:GetZoneParameters is comparatively
	-- expensive so it must not run every frame.
	ZoneRefreshInterval = 3,

	-- Surface sample rig. Each buoyant object gets 4 corner Attachments,
	-- `SampleInset` inside its bounding box, but never closer together than
	-- `SlopeBaselineStuds`: a 3-stud crate only 3 studs wide would divide a
	-- sub-stud height difference by 3 and read the sea as flat, and in "MESH"
	-- mode both corners can land in one triangle and read it as flat exactly.
	-- Widening the baseline is what lets small props tilt with the swell too.
	SampleInset = 0.9,
	SlopeBaselineStuds = 8,

	-- AlignPosition force cap = AssemblyMass * workspace.Gravity * this, and
	-- the rest of the position/orientation gains below are the ship's numbers
	-- (`Ship.Client`: maxForce mass*g*4, MaxVelocity 80, Responsiveness 12,
	-- MaxTorque AssemblyMass*5000, MaxAngularVelocity 8).
	ForceMultiplier = 4,
	MaxVelocity = 80,
	Responsiveness = 12,
	TorqueMultiplier = 5000,
	MaxAngularVelocity = 8,
	AngularResponsiveness = 12,

	-- true -> the AlignPosition uses Enum.ForceLimitMode.PerAxis: the Y cap is
	-- the buoyancy force and the X/Z caps are only the `DriftReturnForce`
	-- share, so the servo can essentially only push vertically. That removes
	-- the whole class of "what reference frame is AlignPosition.Position in"
	-- problems (it is a world goal in OneAttachment mode), stops the
	-- controller damping a player's horizontal shove, and - because
	-- `ForceLimitMode.Magnitude` shares ONE cap across all three axes - it also
	-- stops a sideways goal error from quietly eating the lift budget. The
	-- ship still runs in Magnitude mode, which is why its `(0, TargetY, 0)`
	-- goal is a real problem there and not here (see AUDIT.md B-14).
	VerticalOnlyForce = true,

	-- Soft gains: used instead of the ship's numbers when a prop is not in the
	-- near band (its target only moves at UpdateInterval, so stiff gains make
	-- the bob step) or when it is still far off its goal (just unfrozen, just
	-- splashed, just flung by a player) - then it glides onto the surface
	-- instead of snapping to it.
	SoftMaxVelocity = 14,
	SoftResponsiveness = 8,
	SoftTorqueMultiplier = 1200,
	SoftMaxAngularVelocity = 3,
	SoftAngularResponsiveness = 8,
	SettleDistance = 2, -- studs of vertical error that counts as "far off"
	SettleAngleDegrees = 15, -- and so does this much attitude error

	-- Heading. The hull's yaw is read off physics, smoothed, and re-commanded;
	-- deviations bigger than the deadband are treated as a real push and taken
	-- immediately, so debris can still be kicked around.
	YawDeadbandDegrees = 5,
	YawSmoothing = 0.25,

	-- Fraction of the buoyancy force allowed to pull a pushed prop back toward
	-- the spot it spawned at (its X/Z servo goal). 0 = props stay where a
	-- player left them and drift forever.
	DriftReturnForce = 0.12,

	-- Integral action on the buoyancy goal, Small and Medium only. The servo rides
	-- about a stud low on average (floating/NOTES.md); this bias removes that error.
	-- IntegralGain is studs of goal bias per second per stud of mean height error;
	-- the bias is clamped to IntegralMaxBias studs.
	IntegralGain = 0.3,
	IntegralMaxBias = 1.5,
	IntegralClasses = { Small = true, Medium = true },

	-- Network ownership. "Server" keeps physics authoritative here (determinism
	-- + exploit resistance; the price is that local players push props with one
	-- round trip of latency). "NearestPlayer" hands props inside `OwnDistance`
	-- to the closest client, exactly like the ship is owned by whoever is
	-- driving it, so the player who is looking at it simulates it at 60 fps.
	Ownership = "Server",
	OwnDistance = 150,
	OwnKeepRatio = 1.6, -- keep an owner up to OwnDistance * this, no churn
	MaxOwnedPerPlayer = 64,

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
