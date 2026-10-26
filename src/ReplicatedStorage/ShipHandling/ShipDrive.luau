--!strict
--!optimize 2

-- Ship handling model, shared by Ship.Client (the driver's machine, while someone
-- is aboard) and Ship.Handler (the server, while the seat is empty).
--
-- Everything here is a pure function of velocity, heading, throttle, wind and
-- tuning. There are no services in this file, so both sides compute the same
-- numbers and the model can be checked on its own.
--
-- Units: studs and seconds. The functions return ACCELERATIONS in studs/s^2; the
-- caller multiplies by the hull's AssemblyMass to get the VectorForce.
--
-- Model, in order of what a helmsman feels:
--   * Throttle spools up and down (ThrottleSpool), so the engine never snaps.
--   * Engine thrust is constant, and quadratic drag sets the top speed. Releasing
--     the throttle lets the ship coast down over several seconds, and the drag
--     gets stronger as it slows less quickly at speed.
--   * Throttle against the motion brakes harder (BrakeAccel), without overshoot.
--   * The keel resists sideways motion, so the hull tracks its heading.
--   * Sail: thrust from the apparent wind (true wind minus the hull's own
--     velocity). Nothing in irons, best on a beam reach, a little less dead
--     downwind. The sail also pushes sideways a little (leeway), which the keel
--     damps.
--   * Rudder authority rises with forward speed, so a stopped ship does not spin.

local ShipDrive = {}

export type Tuning = {
	EngineAccel: number, -- studs/s^2 ahead at full throttle
	ReverseAccel: number, -- studs/s^2 astern at full throttle
	BrakeAccel: number, -- extra studs/s^2 when throttle opposes motion
	DragLinear: number, -- 1/s, always on
	DragQuadratic: number, -- 1/stud, grows with speed
	LateralDamping: number, -- 1/s on sideways speed (keel)
	ThrottleSpool: number, -- throttle units per second
	MaxTurnRate: number, -- rad/s at full rudder and full authority
	TurnReferenceSpeed: number, -- studs/s at which the rudder has full authority
	WindSpeed: number, -- studs/s, reference breeze for the sail
	SailAccel: number, -- studs/s^2 from the sail on a beam reach in WindSpeed
	LeewayRatio: number, -- sideways share of the sail push
}

-- Engine-only top speed solves EngineAccel = DragLinear*v + DragQuadratic*v^2,
-- which is about 29 studs/s here (close to the previous fixed 30 studs/s throttle).
ShipDrive.Defaults = {
	EngineAccel = 8,
	ReverseAccel = 2,
	BrakeAccel = 8,
	DragLinear = 0.08,
	DragQuadratic = 0.0067,
	LateralDamping = 1.2,
	ThrottleSpool = 1.5,
	MaxTurnRate = 0.5,
	TurnReferenceSpeed = 6,
	WindSpeed = 14,
	-- Sweep, 14 studs/s breeze: beam reach ~17, downwind ~6, close-hauled ~5.5 studs/s.
	SailAccel = 3.0,
	LeewayRatio = 0.3,
} :: Tuning

-- Every field a hull may override, in the order they appear in Tuning.
local TUNING_FIELDS = {
	"EngineAccel",
	"ReverseAccel",
	"BrakeAccel",
	"DragLinear",
	"DragQuadratic",
	"LateralDamping",
	"ThrottleSpool",
	"MaxTurnRate",
	"TurnReferenceSpeed",
	"WindSpeed",
	"SailAccel",
	"LeewayRatio",
}

-- Resolve the tuning for one hull.
--
-- Until now every ship read Defaults directly, so a 125-stud, 19.5k-mass floating
-- island (MisoSoup), an 88-stud schooner (WoodenShip) and a boathouse all accelerated,
-- turned and stopped exactly like a 45-stud sloop. A hull now overrides any field by
-- carrying a NUMBER attribute of the same name on the model:
--
--     WoodenShip: EngineAccel = 6.6, MaxTurnRate = 0.26
--
-- Nothing else is needed. The Client is cloned against its own ship model and the
-- Handler sits inside the model, so both sides read the same attributes and resolve
-- the same table; a field with no attribute keeps the Defaults value. Attributes are
-- the tuning surface because they can be edited in Studio on the live place and read
-- back, without a script round trip.
function ShipDrive.Resolve(ship: Instance): Tuning
	local tuning = table.clone(ShipDrive.Defaults)
	local overrides = tuning :: any
	for _, field in ipairs(TUNING_FIELDS) do
		local value = ship:GetAttribute(field)
		if typeof(value) == "number" then
			overrides[field] = value
		end
	end
	return tuning
end

-- Engine-only top speed of a hull: the positive root of
-- EngineAccel = DragLinear*v + DragQuadratic*v^2. Used by the handling docs and by the
-- Play check, so the numbers in the table can be predicted instead of only observed.
function ShipDrive.TopSpeed(tuning: Tuning): number
	local a = tuning.DragQuadratic
	local b = tuning.DragLinear
	local c = -tuning.EngineAccel
	if a <= 0 then
		return if b > 0 then tuning.EngineAccel / b else 0
	end
	return (-b + math.sqrt(b * b - 4 * a * c)) / (2 * a)
end

local function ramp(x: number, from: number, to: number): number
	return math.clamp((x - from) / (to - from), 0, 1)
end

-- `windFromDeg` is the angle between the bow and the direction the apparent wind
-- comes FROM: 0 is head-on, 90 a beam wind, 180 dead astern.
function ShipDrive.SailEfficiency(windFromDeg: number): number
	return ramp(windFromDeg, 30, 50) * (1 - 0.15 * ramp(windFromDeg, 110, 180))
end

-- Moves the spooled throttle toward the seat's input at a limited rate.
function ShipDrive.Spool(current: number, target: number, dt: number, tuning: Tuning): number
	local step = tuning.ThrottleSpool * dt
	return current + math.clamp(target - current, -step, step)
end

-- Turn rate in rad/s. Positive `steer` is the same direction the Client always used
-- (the caller subtracts it from the heading). Rudder authority follows the sign of
-- the forward speed, so reversing turns the bow the other way, as a car does.
function ShipDrive.YawRate(forwardSpeed: number, steer: number, tuning: Tuning): number
	local authority = math.clamp(forwardSpeed / tuning.TurnReferenceSpeed, -1, 1)
	return steer * tuning.MaxTurnRate * authority
end

-- Horizontal acceleration (studs/s^2) of the hull.
--   velocity   hull velocity (only X/Z is used)
--   forward    unit horizontal heading
--   right      unit horizontal, 90 degrees to the right of `forward`
--   command    spooled throttle, -1..1
--   dt         frame time, used so braking cannot overshoot zero
--   trueWind   air velocity over the water (horizontal, studs/s)
--   sailAccel  the sail's Tuning.SailAccel for this hull, or 0 for no sail
function ShipDrive.Acceleration(
	velocity: Vector3,
	forward: Vector3,
	right: Vector3,
	command: number,
	dt: number,
	trueWind: Vector3,
	sailAccel: number,
	tuning: Tuning
): Vector3
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = flat.Magnitude
	local forwardSpeed = flat:Dot(forward)
	local sideSpeed = flat:Dot(right)

	local a = Vector3.zero

	-- Engine. Full ahead and full astern use different thrust.
	local engine = if command >= 0 then command * tuning.EngineAccel else command * tuning.ReverseAccel
	a += forward * engine

	-- Braking. Throttle against the motion slows the hull faster than coasting,
	-- capped so it cannot push the speed past zero in one step.
	if command * forwardSpeed < 0 and math.abs(forwardSpeed) > 0.1 then
		local brake = math.min(tuning.BrakeAccel * math.abs(command), math.abs(forwardSpeed) / dt)
		a -= forward * (brake * math.sign(forwardSpeed))
	end

	-- Drag: linear plus quadratic along the heading, and a strong keel damping
	-- on sideways speed.
	local drag = tuning.DragLinear + tuning.DragQuadratic * speed
	a -= forward * (drag * forwardSpeed)
	a -= right * (tuning.LateralDamping * sideSpeed)

	-- Sail. The apparent wind is what the sail actually sees.
	if sailAccel > 0 then
		local apparent = Vector3.new(trueWind.X - flat.X, 0, trueWind.Z - flat.Z)
		local apparentSpeed = apparent.Magnitude
		if apparentSpeed > 1e-3 then
			-- +1 when the wind comes straight over the bow.
			local cosFrom = math.clamp(-apparent:Dot(forward) / apparentSpeed, -1, 1)
			local efficiency = ShipDrive.SailEfficiency(math.deg(math.acos(cosFrom)))
			-- Sail force scales with the square of the apparent wind speed.
			local push = sailAccel * efficiency * (apparentSpeed / tuning.WindSpeed) ^ 2
			a += forward * push
			-- Leeway: the sail pushes the hull downwind of its heading, and the keel
			-- above resists it.
			a -= right * (apparent:Dot(right) / apparentSpeed * push * tuning.LeewayRatio)
		end
	end

	return a
end

return ShipDrive
