-- Settings / HeightLookup / game stubs so src/.../WaveFloat.luau can load headless.
-- The wave table is the real one (Settings/init.luau:133), built with the real
-- Gerstner.new, and it is installed BEFORE WaveFloat loads, because WaveFloat
-- captures `local Waves = Settings.Waves` at load time.

local WL = { 58, 41, 30, 25 }
local ST = { 0.26, 0.20, 0.14, 0.09 }
local DIR = {
	{ 0.92, 0, 0.38 },
	{ -0.35, 0, 0.94 },
	{ 0.71, 0, -0.71 },
	{ -0.96, 0, -0.27 },
}
local Waves = {}
for i = 1, 4 do
	Waves[i] = Gerstner.new(Vector3.new(DIR[i][1], DIR[i][2], DIR[i][3]).Unit, WL[i], ST[i])
end

SETTINGS_STUB = {
	Waves = Waves,
	GRID_SETTINGS = { PLANE_OFFSET = Vector3.new(0, 25, 0) },
}
HEIGHTLOOKUP_STUB = {
	-- Only reached in the MESH path, which this harness does not exercise.
	Lookup = function()
		return -1
	end,
	ClientInit = function() end,
}
Gerstner.Settings = SETTINGS_STUB
Gerstner.HeightLookup = HEIGHTLOOKUP_STUB
REPLICATED_STORAGE_STUB = { Gerstner = Gerstner }
game = {
	GetService = function()
		return REPLICATED_STORAGE_STUB
	end,
}
require = function(m)
	return m
end
CFrame = {
	identity = {},
	fromEulerAnglesXYZ = function()
		return {}
	end,
}
