--!strict
--!optimize 2

-- Swimming model for the player character, shared by the local swim controller
-- (StarterPlayerScripts.SwimClient) and the smoke tests.
--
-- The model is pure: numbers in, numbers out. There are no services here, so it can
-- be checked on its own. The controller does the Roblox work (sampling the wave field,
-- raycasts, writing velocity and orientation).
--
-- How a character floats (the floating-object physics, applied to a person):
--   * The surface is the same analytic wave field the floating objects and ships ride
--     (WaveFloat.HeightAt). The character's root is driven toward that surface by a
--     spring, so it follows the crests and troughs instead of sinking through them.
--   * The root tilts with the local wave slope, like a prop's four-point solve, capped
--     so a swimmer never flips over.
--   * Gravity is cancelled while swimming, so the spring alone sets the height.
--   * Input adds horizontal and vertical swim velocity on top of the spring. Dive keys
--     override the spring, and releasing them lets the swimmer rise back to the surface.
--
-- Nothing here is a floor. The sea has no bottom in the void, so a diver can keep going
-- down. The only thing that ends a swim is leaving the water (or sitting, or dying).

local SwimModel = {}

-- Config fields (typed `any` so the smoke transform can read the file):
-- 	EnterDepth: number, -- studs the root must be below the surface to start swimming
-- 	ExitDepth: number, -- studs the root must rise above the surface to stop (hysteresis)
-- 	FloatOffset: number, -- root height above the surface when floating still
-- 	SpringGain: number, -- vertical speed (studs/s) per stud of height error
-- 	MaxSpringSpeed: number, -- cap on the spring's vertical speed (studs/s)
-- 	SwimSpeed: number, -- horizontal and 3D swim speed (studs/s)
-- 	VerticalSpeed: number, -- dive / rise speed from the keys (studs/s)
-- 	Accel: number, -- how quickly velocity follows the desired value (1/s)
-- 	TiltFactor: number, -- share of the wave slope the body takes on
-- 	MaxTilt: number, -- radians, cap on pitch and roll
-- 	TintFullDepth: number, -- studs below the surface for the full underwater tint

SwimModel.Config = {
	EnterDepth = 1.0,
	ExitDepth = 2.0,
	FloatOffset = 0.0,
	SpringGain = 4,
	MaxSpringSpeed = 12,
	SwimSpeed = 14,
	VerticalSpeed = 10,
	Accel = 6,
	TiltFactor = 0.6,
	MaxTilt = math.rad(25),
	TintFullDepth = 10,
}

local function clamp(x: number, lo: number, hi: number): number
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end
SwimModel.Clamp = clamp

-- How far the root sits above (positive) or below (negative) the wave surface.
function SwimModel.Depth(rootY: number, surfaceY: number): number
	return rootY - surfaceY
end

-- Swimming on or off. `groundBelow` is true when a solid surface sits under the
-- character above the water (a beach, a pier, a ship's deck), so the character walks
-- instead. Hysteresis stops the state chattering while the swimmer bobs at the surface.
function SwimModel.NextState(wasSwimming: boolean, depth: number, groundBelow: boolean, cfg: any?): boolean
	local config = cfg or SwimModel.Config
	if groundBelow then
		return false
	end
	if wasSwimming then
		return depth < config.ExitDepth
	end
	return depth < -config.EnterDepth
end

-- Vertical velocity the spring asks for, pulling the root to surface + FloatOffset.
function SwimModel.SpringSpeed(rootY: number, surfaceY: number, cfg: any?): number
	local config = cfg or SwimModel.Config
	local error = (surfaceY + config.FloatOffset) - rootY
	return clamp(error * config.SpringGain, -config.MaxSpringSpeed, config.MaxSpringSpeed)
end

-- Desired world velocity components. `direction` is the camera-relative input
-- direction (length 0 to 1, may have a Y part when the camera looks up or down).
-- `vertical` is -1 (dive), 0 or +1 (rise). The spring weight drops as input takes over,
-- so holding a dive key is never fought by the surface.
function SwimModel.Desired(
	dirX: number,
	dirY: number,
	dirZ: number,
	vertical: number,
	springY: number,
	cfg: any?
): (number, number, number)
	local config = cfg or SwimModel.Config
	local inputY = dirY * config.SwimSpeed + vertical * config.VerticalSpeed
	local inputMagnitude = math.abs(inputY) / config.SwimSpeed
	local springWeight = 1 - clamp(inputMagnitude, 0, 1)
	return dirX * config.SwimSpeed, inputY + springY * springWeight, dirZ * config.SwimSpeed
end

-- Move one velocity component toward its desired value with exponential easing.
function SwimModel.Approach(current: number, desired: number, dt: number, cfg: any?): number
	local config = cfg or SwimModel.Config
	local alpha = 1 - math.exp(-config.Accel * math.max(dt, 0))
	return current + (desired - current) * alpha
end

-- Pitch and roll the body takes from the four-point wave sample. Same construction as
-- WaveFloat.Solve: front/back give pitch over `length`, right/left give roll over
-- `width`. Positive values match the ship and prop solve.
function SwimModel.Tilt(
	front: number,
	back: number,
	right: number,
	left: number,
	length: number,
	width: number,
	cfg: any?
): (number, number)
	local config = cfg or SwimModel.Config
	local pitch = math.atan((front - back) / math.max(length, 1e-3)) * config.TiltFactor
	local roll = math.atan((right - left) / math.max(width, 1e-3)) * config.TiltFactor
	return clamp(pitch, -config.MaxTilt, config.MaxTilt), clamp(roll, -config.MaxTilt, config.MaxTilt)
end

-- Underwater tint strength, 0 above the surface and 1 at TintFullDepth below it.
-- `cameraDepth` is the camera's depth below the surface (positive when submerged).
function SwimModel.TintAlpha(cameraDepth: number, cfg: any?): number
	local config = cfg or SwimModel.Config
	return clamp(cameraDepth / config.TintFullDepth, 0, 1)
end

return SwimModel
