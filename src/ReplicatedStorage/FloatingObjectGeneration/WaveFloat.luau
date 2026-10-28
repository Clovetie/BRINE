--!nonstrict
--!optimize 2

--[[
	WaveFloat
	=========
	One place that turns "where is the ocean surface right now" into a mover
	constraint goal, so that every floater in BRINE rides the water with the
	SAME model as the player-driven ship:

		1. sample the surface at four points that are real `Attachment`s on the
		   hull, so the samples roll and pitch with the object (this is exactly
		   what `Main.TopLeft/TopRight/BottomLeft/BottomRight` are on the ship);
		2. average the samples for the ride height and difference them for the
		   wave slope (pitch/roll);
		3. apply the ship's proportional drag term and its airborne gate, so a
		   floater that leaves the water falls back in instead of snapping;
		4. return `(height, orientation, depth)` - the ship's own triple, as
		   numbers and a CFrame rather than a packed world position - so the
		   caller drives `AlignPosition`/`AlignOrientation` the way
		   `Workspace.singletons.Ship.Client` does.

	`FloatingObjectGenerator` uses this for every buoyant object. It replaces an
	older "cheap single-point bob" that sampled `HeightLookup` with the `FAST`
	method and commanded NO tilt at all for small props. Two things were wrong
	with that:

		* `FAST` is `Gerstner:GetApproximateHeight`, a folded-|sin| stand-in for
		  the wave sum, so objects bobbed to a *different* waveform than the one
		  the ocean mesh is displaced with - visibly out of phase with the water
		  they were supposed to be sitting on;
		* with no pitch/roll, a crate sat perfectly flat on a 30 degree slope.

	Four samples with a slope baseline fixes both, and costs one pass over the
	wave table each (no triangle search), so it stays affordable for a few
	hundred props.

	Height sources (`Buoyancy.HeightSource`)
		"ANALYTIC" (default)
			`Gerstner.ComputeTransform` evaluated at each sample point: the very
			same wave field `Gerstner.Serial.Setup` displaces the ocean mesh
			with, but continuous. A small prop between two mesh vertices still
			gets the true local slope instead of the flat (or discontinuously
			jumping) slope a piecewise-linear triangle grid gives it. Needs no
			`EditableMesh`, no `HeightLookup.ClientInit`, and works on the
			server. Also covers whirlpools, which `HeightLookup` only applies in
			its `PRECISE` branch.
		"MESH"
			`HeightLookup.Lookup` at every sample - literally what the ship
			client does. Highest fidelity to the rendered triangles, but each
			lookup searches the triangle grid, so reserve it for hulls that are
			actually near a player. Widen `SlopeBaselineStuds` past one mesh cell
			in this mode, or two corners inside one triangle report a flat sea.

	References (official Roblox docs):
		Mover constraints https://create.roblox.com/docs/physics/mover-constraints
		AlignPosition     https://create.roblox.com/docs/reference/engine/classes/AlignPosition
		AlignOrientation  https://create.roblox.com/docs/reference/engine/classes/AlignOrientation
		Attachment        https://create.roblox.com/docs/reference/engine/classes/Attachment
		BasePart          https://create.roblox.com/docs/reference/engine/classes/BasePart
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Gerstner = require(ReplicatedStorage.Gerstner)
local Settings = require(ReplicatedStorage.Gerstner.Settings)
local Helper = require(ReplicatedStorage.Gerstner.Helper)
local HeightLookup = require(ReplicatedStorage.Gerstner.HeightLookup)

local Waves = Settings.Waves
local PLANE_Y = Settings.GRID_SETTINGS.PLANE_OFFSET.Y

-- `HeightLookup.Lookup` documents -1 as its "could not resolve a height"
-- result. The wave field lives at PLANE_Y +/- summed amplitudes, so a *real*
-- height of exactly -1 is only possible with a waterline near sea level AND a
-- trough landing on it; compare against the sentinel itself rather than a
-- range so both readings stay honest.
local LOOKUP_FAILED = -1

-- Copied from BoatManager deliberately: these are the constants that make the
-- ship feel right, and the whole point of this module is that floaters agree.
local DRAG_COEFFICIENT = 0.075
local AIRBORNE_DEPTH = -0.5

local abs = math.abs
local atan2 = math.atan2
local min = math.min

-- The mesh draws a near-shore vertex at only a fraction of its wave height (Helper applies
-- `SHORE_HEIGHT_FACTOR` in both LOD paths). Physics was NOT applying it, so a crate beached in
-- the shallows bobbed with the full wave while the water around it moved by 15% of that - a real
-- R8 disagreement, not a rounding error. Both sides now read the one constant.
local SHORE_HEIGHT_FACTOR = Helper.SHORE_HEIGHT_FACTOR or 0.15

-- `Helper.GetVertexTransparency` caches its raycasts in a SharedTable (that is how the worker keeps
-- it off the per-vertex hot path). Physics gets its own private cache rather than writing into the
-- mesh's `VertexTransparency` table: the two run on different machines and on different clocks, and
-- sharing one cache would let a client's island set decide a server's buoyancy. Only reachable
-- while DEPTH_ENABLED is true, which is not the shipped configuration.
local SHORE_TABLE = nil
local shoreTableTried = false
local function getShoreTable()
	if shoreTableTried then
		return SHORE_TABLE
	end
	shoreTableTried = true
	local registry = game:GetService("SharedTableRegistry")
	local ok, table_ = pcall(function()
		return registry:GetSharedTable("WaveFloatShoreCache")
	end)
	if not (ok and table_) then
		local made, fresh = pcall(function()
			local t = SharedTable.new()
			registry:SetSharedTable("WaveFloatShoreCache", t)
			return t
		end)
		-- // plain if/else, not an if-expression: the smoke harness's loader is luaparse-based
		-- // (defect D-16) and cannot parse Luau if-expressions.
		if made then
			table_ = fresh
		else
			table_ = nil
		end
	end
	SHORE_TABLE = table_
	return SHORE_TABLE
end

local WaveFloat = {}

--[[
	Which clock a caller passes as `t`.

	The ocean mesh is displaced with `workspace:GetServerTimeNow()`. Every consumer of this module
	has to pass the same clock or the physics rides a different wave than the one drawn, and the
	error is a phase shift, not a constant offset - it looks like a ship "floating wrong" and it is
	invisible to any test that samples one surface. `WaveFloat.CheckClock(t)` is a cheap guard for
	DEBUG builds: it warns (once per module load per magnitude of error) when a caller passes
	`tick()`/`os.clock()`-style time instead.
]]
local clockWarned = false
function WaveFloat.CheckClock(t: number)
	if Settings.DEBUG ~= true or clockWarned or t == nil then
		return
	end
	local now = workspace:GetServerTimeNow()
	if abs(now - t) > 5 then
		clockWarned = true
		warn(string.format(
			"WaveFloat: sample time %.3f is %.1f s away from workspace:GetServerTimeNow(); the water is drawn with the server clock, so pass that (or a time derived from it).",
			t, t - now
		))
	end
end

-- Sampling -------------------------------------------------------------------

--[[
	Horizontal inverse of the Gerstner displacement.

	`Gerstner.ComputeTransform` maps a REST point to where that point is DRAWN:
	`rest + D(rest)`. So the surface the player sees above a world XZ belongs to
	the rest point that LANDS there. Evaluating `D(worldXZ).Y` instead - which is
	what this module used to do - samples the wave at the wrong horizontal place,
	and the two heights differ by (local slope x horizontal shift).

	Measured over 100 points with tools/measure-height-error.sh: at SeaState 1.0
	the shift is 1.96 studs on average and 3.08 at the p99, and the height error
	it caused was p99 = 1.30 studs. That is the "waves colliding" symptom: a hull
	or crate could sit up to 1.3 studs off the visible water, and its pitch/roll
	came from a slope sampled at the wrong place too.

	Fixed-point iteration `rest <- worldXZ - D(rest).XZ` converges because the
	steepness sum (0.69) is below 1; the measured rate is about 1/3 per step, so
	three steps take the p99 error to 0.009 studs. This deliberately re-uses
	`ComputeTransform` instead of deriving an analytic Jacobian, so the wave math
	keeps exactly one definition.
]]
WaveFloat.INVERSE_STEPS = 3

-- Horizontal shift (studs) below which inverting is not worth the work: the
-- residual error is then slope x shift, i.e. under 0.69 x 0.05 = 0.035 studs.
WaveFloat.INVERSE_SKIP = 0.05

--[[
	World Y of the drawn surface at a world-space point, after the horizontal
	inverse. `phase`, `speed` and `amplitude` are the zone multipliers, passed
	through unchanged to every evaluation so the inverse solves the same field
	the mesh is displaced with.
]]
local function surfaceHeight(point: Vector3, t: number, phase: number, speed: number, amplitude: number): number
	if Waves == nil then
		return PLANE_Y
	end

	local direct = Gerstner.ComputeTransform(Waves, point, t, phase, speed, amplitude)
	if WaveFloat.INVERSE_STEPS <= 0 or (abs(direct.X) < WaveFloat.INVERSE_SKIP and abs(direct.Z) < WaveFloat.INVERSE_SKIP) then
		-- Calm patch: the shift is small enough that the naive read is already
		-- inside the 0.1 stud budget, so skip the iteration entirely.
		return PLANE_Y + direct.Y
	end

	-- The waves are horizontal-only in their direction vectors, so the rest
	-- point's own Y never enters a phase; carry it through anyway so this keeps
	-- working if a wave ever gets a vertical direction.
	--
	-- The first iteration reuses `direct` (the sample already taken above), so
	-- N steps cost N+1 evaluations rather than N+2.
	local restX = point.X - direct.X
	local restZ = point.Z - direct.Z
	for _ = 2, WaveFloat.INVERSE_STEPS do
		local disp = Gerstner.ComputeTransform(Waves, Vector3.new(restX, point.Y, restZ), t, phase, speed, amplitude)
		restX = point.X - disp.X
		restZ = point.Z - disp.Z
	end

	return PLANE_Y + Gerstner.ComputeTransform(Waves, Vector3.new(restX, point.Y, restZ), t, phase, speed, amplitude).Y
end

--[[
	World Y of the water surface at a world-space point, with the island /
	whirlpool zone multipliers applied.

	`HeightLookup.Lookup` takes its multipliers as (speed, phase, amplitude)
	while `Gerstner.ComputeTransform` takes them as (phase, speed, amplitude) -
	they are NOT the same order, so both translations live here instead of at
	each call site.

	Returns `nil` when a MESH lookup could not resolve the surface: the caller
	then keeps its previous target rather than dropping the object out of the
	sky.
]]
function WaveFloat.HeightAt(point: Vector3, zone, source: string?, method: string?, t: number): number?
	local phase, speed, amplitude = 1, 1, 1
	if zone ~= nil then
		phase = zone.PhaseMultiplier or 1
		speed = zone.SpeedMultiplier or 1
		amplitude = zone.AmplitudeMultiplier or 1
	end

	-- `zone` is optional everywhere in this module, so `zone.CURRENT_ZONE` has to be reached
	-- through a guard: the MESH path used to index it directly and threw for every caller that
	-- passed no zone (the swimming, fishing and ambience callers all do).
	local currentZone = nil
	if zone ~= nil then
		currentZone = zone.CURRENT_ZONE
	end

	WaveFloat.CheckClock(t)

	if source == "MESH" then
		local height =
			HeightLookup.Lookup(point, method or "PRECISE", false, speed, phase, amplitude, currentZone)
		if height == LOOKUP_FAILED or height ~= height then
			return nil
		end
		return height
	end

	local height = surfaceHeight(point, t, phase, speed, amplitude)

	if currentZone ~= nil and currentZone.Type == "Whirlpool" then
		-- Same call HeightLookup makes for its PRECISE triangles: the vortex
		-- pulls the surface down and floaters have to follow it down.
		height = height + Gerstner.GetVortexTransform(currentZone, point, nil, t, nil).Y
	end

	-- Draw-parity with the mesh: near-shore vertices are scaled toward the waterline, so the
	-- height reported here is scaled toward the waterline by the same factor. Only the wave
	-- displacement is scaled - PLANE_Y, the waterline itself, is not.
	if Settings.DEPTH_ENABLED == true then
		local shoreTable = getShoreTable()
		if shoreTable ~= nil then
			local shore = Helper.GetVertexTransparency(point, shoreTable, 1)
			if Helper.IsVertexNearShore(shore) then
				height = PLANE_Y + (height - PLANE_Y) * SHORE_HEIGHT_FACTOR
			end
		end
	end
	return height
end

-- Solver ---------------------------------------------------------------------

--[[
	The ship's buoyancy model, sampled through `WaveFloat.HeightAt`.

		* `points` is ordered exactly like BoatManager's: [1] front-left,
		  [2] front-right, [3] back-left, [4] back-right, with FRONT = -Z and
		  RIGHT = +X of the hull.
		* `length` / `width` must be the distances those sample points actually
		  sit at (the generator widens them for small props so the slope it
		  measures is meaningful - see `Buoyancy.SlopeBaselineStuds`).
		* `waterlineY` is the hull's bottom reference, mirroring the ship's
		  `Main.Center` attachment. Getting this wrong is not a rounding
		  error: with a tall template (a wreck with a mast, a dock with a
		  cabin) the bounding-box centre sits far above the water, the depth
		  reads as "airborne", the servo switches off, and the object sinks
		  through the ocean until the kill-depth reaper gets it.
		* `rideHeight` is how far the reference point rides above the surface
		  (`FloatRatio`), which is the generator's per-class "how sunk is
		  this" knob.

	Returns `(targetY, orientation, clampedDepth, lookupFailed)` - the ship's
	triple, with the height as a plain number and `nil` meaning "airborne, let
	gravity handle it". `AlignPosition.Position` is a *world* goal in
	OneAttachment mode, so the caller owns X/Z and only takes the Y from here
	(see `FloatingObjectGenerator.applyBuoyancyTarget`).
]]
function WaveFloat.Solve(
	points: { Attachment },
	centerOfMassY: number,
	waterlineY: number,
	length: number,
	width: number,
	rideHeight: number,
	zone,
	source: string?,
	method: string?,
	t: number
)
	local frontLeft = WaveFloat.HeightAt(points[1].WorldPosition, zone, source, method, t)
	local frontRight = WaveFloat.HeightAt(points[2].WorldPosition, zone, source, method, t)
	local backLeft = WaveFloat.HeightAt(points[3].WorldPosition, zone, source, method, t)
	local backRight = WaveFloat.HeightAt(points[4].WorldPosition, zone, source, method, t)

	if frontLeft == nil or frontRight == nil or backLeft == nil or backRight == nil then
		return nil, CFrame.identity, 0, true
	end

	local front = (frontLeft + frontRight) / 2
	local back = (backLeft + backRight) / 2
	local left = (frontLeft + backLeft) / 2
	local right = (frontRight + backRight) / 2

	-- Same construction as BoatManager: a higher front lifts the bow, so the
	-- rotation is applied about X; a higher right lifts the starboard side, so
	-- it is applied about Z. Yaw is NOT part of this CFrame - the caller owns
	-- the heading and composes it in front.
	local orientation = CFrame.fromEulerAnglesXYZ(atan2(front - back, length), 0, atan2(right - left, width))

	local surfaceY = (front + back) / 2
	local depth = surfaceY - waterlineY
	if depth <= AIRBORNE_DEPTH then
		-- Clear of the water: let gravity handle the splash-down.
		return nil, orientation, 0, false
	end

	local clamped = min(depth, 0)
	local targetHeight = surfaceY + clamped
	local drag = (centerOfMassY - targetHeight) * DRAG_COEFFICIENT
	return surfaceY + rideHeight - drag, orientation, clamped, false
end

-- Heading --------------------------------------------------------------------

-- Angle delta wrapped to (-pi, pi].
local function wrapAngle(delta: number): number
	local twoPi = math.pi * 2
	return ((delta + math.pi) % twoPi) - math.pi
end

--[[
	The heading a buoyant object should be *commanded* to hold.

	`AlignOrientation` wants a full attitude every refresh, and reading the
	hull's yaw off a bobbing, rolling part is noisy: that noise is fed straight
	back into the goal and the prop slowly spins up on its own. The ship does
	not have the problem - it commands an integrated steering rotation. So
	smooth the measured yaw, and only snap to it once the deviation is clearly
	a real push, so players can still spin debris around.
]]
function WaveFloat.AdvanceYaw(current: number, measured: number, deadband: number, smoothing: number): number
	local delta = wrapAngle(measured - current)
	if abs(delta) > deadband then
		return measured
	elseif abs(delta) < 1e-5 then
		return current
	end
	return current + delta * smoothing
end

return WaveFloat
