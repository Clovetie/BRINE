--!nocheck
-- Measurement: how much of the TROUGH -> CREST colour range the ocean's height ramp actually uses.
-- Run by tools/measure/colour-ramp.sh, which loads the real src/.../Gerstner/Helper.luau.

local TROUGH = SETTINGS_STUB.WAVE_COLORS.TROUGH
local CREST = SETTINGS_STUB.WAVE_COLORS.CREST

-- Blend factor of a colour along TROUGH -> CREST (the ramp's own axis), 0 = TROUGH, 1 = CREST.
local function blendOf(c)
	local dr = CREST.R - TROUGH.R
	local db = CREST.B - TROUGH.B
	local a = (c.R - TROUGH.R) / dr
	local b = (c.B - TROUGH.B) / db
	return (a + b) / 2
end

-- The ramp that shipped before this change, kept for a side-by-side number.
local function oldBlend(y)
	if y < -1 then
		y = -1
	end
	return math.min(((y + -1) * 4) / 30, 1)
end

print(string.format("CREST_ENVELOPE (sum of the shipped wave amplitudes) = %.4f studs", Helper.CREST_ENVELOPE))
print("")
print("live sea, measured from the mesh (docs/audit/10-water-look.md): |Y| max 2.92, typical max 2.35")
print(string.format("%8s %10s %10s %10s", "Y", "old blend", "new blend", "new colour"))
local samples = { -4.7317, -2.92, -2.35, -1, 0, 1, 2.35, 2.92, 4.7317 }
for _, y in samples do
	local c = Helper.GetVertexColor(y, 0, 1)
	print(string.format("%8.3f %10.3f %10.3f %10.3f", y, oldBlend(y), blendOf(c), blendOf(c)))
end

print("")
local waterline = Helper.GetVertexColor(0, 0, 1)
print(string.format("GetVertexColor(0,0,1)            = blend %.3f", blendOf(waterline)))
print(string.format("Helper.WATERLINE_COLOR          = blend %.3f", blendOf(Helper.WATERLINE_COLOR)))
print(string.format("whitecaps possible at all?      %s (WHITECAP_HEIGHT %.1f > envelope %.4f)",
	Helper.CREST_ENVELOPE > SETTINGS_STUB.WHITECAP_HEIGHT and "yes" or "NO", SETTINGS_STUB.WHITECAP_HEIGHT, Helper.CREST_ENVELOPE))

-- A ramp is only correct if it spans the pair and never leaves it.
local lo, hi = 1, 0
for i = 0, 200 do
	local y = -Helper.CREST_ENVELOPE + (2 * Helper.CREST_ENVELOPE) * (i / 200)
	local b = blendOf(Helper.GetVertexColor(y, 0, 1))
	lo = math.min(lo, b)
	hi = math.max(hi, b)
end
print(string.format("ramp span over the full envelope: %.3f .. %.3f (wanted 0.000 .. 1.000)", lo, hi))
