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

local WaveFloat = {}

-- Sampling -------------------------------------------------------------------

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

	if source == "MESH" then
		local height =
			HeightLookup.Lookup(point, method or "PRECISE", false, speed, phase, amplitude, zone.CURRENT_ZONE)
		if height == LOOKUP_FAILED or height ~= height then
			return nil
		end
		return height
	end

	local height = PLANE_Y
	if Waves ~= nil then
		height = height + Gerstner.ComputeTransform(Waves, point, t, phase, speed, amplitude).Y
	end

	local currentZone = zone and zone.CURRENT_ZONE
	if currentZone ~= nil and currentZone.Type == "Whirlpool" then
		-- Same call HeightLookup makes for its PRECISE triangles: the vortex
		-- pulls the surface down and floaters have to follow it down.
		height = height + Gerstner.GetVortexTransform(currentZone, point, nil, t, nil).Y
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
