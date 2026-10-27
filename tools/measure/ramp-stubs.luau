--!nocheck
-- Colour3 / Camera / workspace / Settings stubs so src/ReplicatedStorage/Gerstner/Helper.luau
-- can load headless under the plain Luau interpreter (.tools/bin/luau).
--
-- Only what Helper.luau touches at load and inside GetVertexColor is implemented. The wave table
-- is built with the real Gerstner.new from the real Settings numbers, so CREST_ENVELOPE below is
-- the shipped envelope, not a copy of it.

local function Color3New(r, g, b)
	return {
		R = r,
		G = g,
		B = b,
		Lerp = function(self, other, alpha)
			-- Roblox clamps the alpha; keep that behaviour so a negative blend would show up here.
			local a = math.max(0, math.min(1, alpha))
			return Color3New(
				self.R + (other.R - self.R) * a,
				self.G + (other.G - self.G) * a,
				self.B + (other.B - self.B) * a
			)
		end,
	}
end

Color3 = {}
Color3.new = Color3New
Color3.fromRGB = function(r, g, b)
	return Color3New(r / 255, g / 255, b / 255)
end

local function Signal()
	return { Connect = function() end }
end

workspace = {
	Camera = {
		FieldOfView = 70,
		ViewportSize = { X = 1920, Y = 1080 },
		GetPropertyChangedSignal = function()
			return Signal()
		end,
	},
	FindFirstChild = function()
		return nil
	end,
	ChildAdded = Signal(),
}

-- Real Settings numbers (src/ReplicatedStorage/Gerstner/Settings/init.luau).
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
	GRID_SETTINGS = { CHUNK_SIZE = 100, PLANE_OFFSET = Vector3.new(0, 25, 0) },
	WAVE_COLORS = {
		CREST = Color3.fromRGB(77, 166, 156),
		TROUGH = Color3.fromRGB(46, 89, 118),
		VORTEX = Color3.fromRGB(18, 28, 33),
		SHORE = Color3.fromRGB(60, 186, 171),
	},
	UV_SCROLL_SPEED = 1 / 12,
	UV_SCROLL_DIRECTION = Vector2.new(1, 1),
	DEPTH_ENABLED = false,
	DEPTH_RAY_LENGTH = Vector3.new(0, -15, 0),
	DEPTH_RAY_OFFSET = Vector3.new(0, 5, 0),
	WHITECAP_HEIGHT = 6,
	SHORE_TRANSPARENCY = 0.2,
}

-- RaycastParams / Enum are touched at load (the shore raycast filter), not by the ramp itself.
Enum = { RaycastFilterType = { Include = "Include" } }
RaycastParams = {
	new = function()
		return {}
	end,
}

-- Helper.luau does `require(script.Parent.Settings)`; give it a parent that resolves.
script = { Name = "Helper", Parent = { Settings = SETTINGS_STUB, Gerstner = { Settings = SETTINGS_STUB } } }

game = {
	GetService = function()
		return { Gerstner = { Settings = SETTINGS_STUB } }
	end,
}
require = function(m)
	return m
end
