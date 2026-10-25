--!nonstrict
--!optimize 2

-- ROADMAP 7.1: shared density field for islands and floating objects.
-- Smooth noise makes archipelagos (dense) and open water (sparse) instead of an
-- even, periodic grid. It is a pure function of position and the world seed, so
-- every server with the same seed sees the same layout.

local Density = {}

-- Returns t in [0, 1]: 0 = open water, 1 = archipelago core. `scale` is the broad
-- wavelength in studs; a finer octave adds irregular edges to the clusters.
function Density.value(x: number, z: number, seed: number, scale: number): number
	local s = math.max(scale, 1)
	local ox = (seed % 4093) * 0.7311
	local oz = (seed % 3947) * 1.1783
	local broad = math.noise(x / s + ox, z / s + oz, 0.25)
	local detail = math.noise(x / (s * 0.35) + ox * 2.1, z / (s * 0.35) + oz * 1.7, 0.75)
	local n = broad + 0.35 * detail
	return math.clamp(0.5 + n * 1.2, 0, 1)
end

-- Maps t to a probability between minChance (open water) and maxChance (core).
function Density.chance(t: number, minChance: number, maxChance: number): number
	return minChance + (maxChance - minChance) * t
end

return Density
