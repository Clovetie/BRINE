--!strict
--!optimize 2

-- Guard for a ship hull, shared by Ship.Handler (server, while the seat is empty, and
-- for the anti-climb while occupied) and Ship.Client (the driver's machine, which owns
-- the hull while someone is aboard).
--
-- Horizontal motion is never touched. A ship still pushes unanchored objects aside, and
-- fixed ones still stop it.
--
--   1. Anti-climb. While the hull touches a part outside the ship, a rising hull is held
--      at zero rise, so ships do not ride up onto things.
--
--   2. Anti-sink. The buoyancy servo's goal is the waterline the hull should ride at.
--      `gap` is how far the hull sits BELOW that goal (negative when above it).
--        * In contact and more than ContactBand below the goal, the hull may not move
--          down (vertical velocity is held at zero).
--        * Out of contact and more than SinkMargin below, a soft floor lifts the hull
--          back toward the goal (proportional, capped at MaxRise).
--        * Below the band, the servo's force limit rises with the gap (ServoReserve).
--          This is the part that holds against a sustained load. A velocity clamp alone
--          cannot: a steady force still moves the hull every physics step, so zeroing
--          velocity each frame does not stop a sink. The servo has to out-push the load.
--
-- Everything here is pure (no services, no instances), so the rules can be checked on
-- their own. Callers pass the touching test as a function, so parts are only scanned
-- when the answer can change the result.

local ShipGuard = {}

-- Fields: SinkMargin, ContactBand, SinkGain, MaxRise, ReserveGain, ReserveMax.
-- Plain table, typed `any` at the call sites so the smoke transform can read it.
ShipGuard.Defaults = {
	SinkMargin = 2.5, -- studs below the goal before the floor lifts the hull
	ContactBand = 1.0, -- studs below the goal where contact holds the hull
	SinkGain = 6, -- studs/s of lift per stud beyond SinkMargin
	MaxRise = 20, -- cap on the floor's lift, studs/s
	ReserveGain = 1.5, -- extra servo force, as a share of the weight, per stud below the band
	ReserveMax = 8, -- cap on that extra force (multiples of the hull's weight)
}

local function clamp(x: number, lo: number, hi: number): number
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

-- How far the hull sits below its servo goal. Zero when airborne (no goal).
function ShipGuard.Gap(moverY: number, goalY: number?): number
	if goalY == nil then
		return 0
	end
	return goalY - moverY
end

-- Extra servo force, as a multiple of the hull's weight, to hold a sinking hull up.
function ShipGuard.ServoReserve(gap: number, cfg: any?): number
	local config = cfg or ShipGuard.Defaults
	return clamp((gap - config.ContactBand) * config.ReserveGain, 0, config.ReserveMax)
end

-- Returns the vertical velocity the hull should have this frame.
--   vy:          current vertical velocity
--   moverY:      height of the reference point the servo drives (the mover)
--   goalY:       the servo goal for that same point, or nil when airborne
--   isTouching:  true while the hull touches a part outside the ship
function ShipGuard.ResolveVertical(
	vy: number,
	moverY: number,
	goalY: number?,
	isTouching: () -> boolean,
	cfg: any?
): number
	local config = cfg or ShipGuard.Defaults
	local gap = ShipGuard.Gap(moverY, goalY)

	-- Only scan for contact when the answer can change: a rising hull, or a hull
	-- below its goal band.
	local touching = false
	if vy > 0 or (goalY ~= nil and gap > config.ContactBand) then
		touching = isTouching()
	end

	if touching then
		-- Anti-climb: never rise while in contact with something outside the ship.
		if vy > 0 then
			vy = 0
		end
		-- Anti-sink under contact: once below the goal band, contact holds the hull.
		if goalY ~= nil and gap > config.ContactBand and vy < 0 then
			vy = 0
		end
		return vy
	end

	-- Out of contact: lift the hull back toward its goal when it is well below.
	if goalY ~= nil and gap > config.SinkMargin then
		local lift = math.min(config.MaxRise, (gap - config.SinkMargin) * config.SinkGain)
		if vy < lift then
			vy = lift
		end
	end
	return vy
end

return ShipGuard
