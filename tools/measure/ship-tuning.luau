--!nocheck
-- Per-hull handling check. Runs the REAL ShipDrive.luau (no services in it, so it loads
-- under the plain Luau interpreter) against the attribute sets actually set on each hull
-- in Studio, and prints what a helmsman would feel:
--
--   * resolved tuning (so an attribute typo shows up as a field that did not take)
--   * engine-only top speed (ShipDrive.TopSpeed)
--   * time to 90% of top speed and distance to get there, by integrating
--     ShipDrive.Acceleration forward-only with a full-throttle spool
--   * coast distance and time from top speed to 20% (throttle released)
--   * steady turn rate at speed and the resulting turn radius
--
-- Every number comes from calling the shipped functions. Nothing here re-derives them.

local function instanceWith(attrs)
	return setmetatable({ _attrs = attrs }, {
		__index = {
			GetAttribute = function(self, name)
				return self._attrs[name]
			end,
		},
	})
end

-- The steering rule: every hull's steady turn radius at its own top speed is about
-- 1.3 hull lengths, the ratio the reference ServerBoat already has (58.2 / 45.0).
-- MaxTurnRate is then TopSpeed / (1.3 * length), rounded to two decimals, so a long
-- hull is not a speedboat that pivots on the spot.
--
-- Mirrors the tables set in Studio on 2026-10-26. ServerBoat is the physics reference and
-- keeps Defaults; it is not driven by ShipDrive at all (its own legacy Handler runs it),
-- so it appears here only as the numbers the other hulls are measured against.
local HULLS = {
	{ name = "ServerBoat (reference, Defaults)", length = 45.0, mass = 1556, attrs = {} },
	{ name = "WoodenShip", length = 88.0, mass = 2663, attrs = {
		EngineAccel = 6.6, ReverseAccel = 1.7, BrakeAccel = 7.0,
		DragLinear = 0.08, DragQuadratic = 0.0067, LateralDamping = 1.4,
		ThrottleSpool = 1.2, MaxTurnRate = 0.23, TurnReferenceSpeed = 8,
	} },
	{ name = "MisoSoup", length = 125.4, mass = 19565, attrs = {
		EngineAccel = 3.6, ReverseAccel = 0.9, BrakeAccel = 6.0,
		DragLinear = 0.08, DragQuadratic = 0.0067, LateralDamping = 2.0,
		ThrottleSpool = 0.8, MaxTurnRate = 0.11, TurnReferenceSpeed = 10,
	} },
	{ name = "Boathouse", length = 45.0, mass = 2757, attrs = {
		EngineAccel = 2.4, ReverseAccel = 0.7, BrakeAccel = 5.0,
		DragLinear = 0.08, DragQuadratic = 0.0067, LateralDamping = 1.2,
		ThrottleSpool = 1.0, MaxTurnRate = 0.24, TurnReferenceSpeed = 6,
	} },
}

local dt = 1 / 60

-- Full throttle from rest, spooling like the Client does. Returns time and distance to
-- reach `fraction` of the engine-only top speed.
local function spoolRun(tuning, topSpeed, fraction, releaseAtTop)
	local forward = Vector3.new(0, 0, -1)
	local right = forward:Cross(Vector3.new(0, 1, 0))
	local velocity = Vector3.new(0, 0, 0)
	local command = 0
	local t, travelled = 0, 0
	local target = topSpeed * fraction
	while t < 120 do
		command = ShipDrive.Spool(command, 1, dt, tuning)
		local a = ShipDrive.Acceleration(velocity, forward, right, command, dt, Vector3.new(0, 0, 0), 0, tuning)
		velocity += a * dt
		travelled += velocity.Magnitude * dt
		t += dt
		if not releaseAtTop and velocity.Magnitude >= target then
			return t, travelled, velocity.Magnitude
		end
		if releaseAtTop and t >= releaseAtTop then
			return t, travelled, velocity.Magnitude
		end
	end
	return t, travelled, velocity.Magnitude
end

-- Coast: from top speed with the throttle closed, until 20% of it is left.
local function coastRun(tuning, topSpeed)
	local forward = Vector3.new(0, 0, -1)
	local right = forward:Cross(Vector3.new(0, 1, 0))
	local velocity = forward * topSpeed
	local t, travelled = 0, 0
	local floor = topSpeed * 0.2
	while velocity.Magnitude > floor and t < 300 do
		local a = ShipDrive.Acceleration(velocity, forward, right, 0, dt, Vector3.new(0, 0, 0), 0, tuning)
		velocity += a * dt
		travelled += velocity.Magnitude * dt
		t += dt
	end
	return t, travelled, velocity.Magnitude
end

print(string.format("%-34s %7s %7s %7s %8s %7s %7s %7s", "hull", "top", "0-90%", "dist", "turnR", "turn/s", "coast", "cdist"))
print(string.rep("-", 96))
for _, hull in ipairs(HULLS) do
	local tuning = ShipDrive.Resolve(instanceWith(hull.attrs))
	local top = ShipDrive.TopSpeed(tuning)
	local t90, d90 = spoolRun(tuning, top, 0.90, nil)
	local coastT, coastD = coastRun(tuning, top)
	-- Steady turn at the top speed: the rudder has full authority above
	-- TurnReferenceSpeed, so the yaw rate is MaxTurnRate there.
	local speedForTurn = top
	local yaw = 0
	local forward = Vector3.new(0, 0, -1)
	local steer = 1
	local authority = math.clamp(speedForTurn / tuning.TurnReferenceSpeed, -1, 1)
	yaw = steer * tuning.MaxTurnRate * authority
	local radius = if yaw ~= 0 then speedForTurn / yaw else math.huge
	print(string.format(
		"%-34s %7.2f %7.2f %7.1f %8.1f %7.3f %7.2f %7.1f",
		hull.name, top, t90, d90, radius, yaw, coastT, coastD
	))
	-- Print any field the hull overrode, so a misspelled attribute is visible.
	local overridden = {}
	for _, field in ipairs({
		"EngineAccel", "ReverseAccel", "BrakeAccel", "DragLinear", "DragQuadratic",
		"LateralDamping", "ThrottleSpool", "MaxTurnRate", "TurnReferenceSpeed",
		"WindSpeed", "SailAccel", "LeewayRatio",
	}) do
		if hull.attrs[field] ~= nil then
			table.insert(overridden, string.format("%s=%.3f", field, hull.attrs[field]))
		end
	end
	print("    overrides: " .. (#overridden > 0 and table.concat(overridden, " ") or "none (Defaults)"))
end
