--!nocheck
-- Does the ocean surface fold over itself (waves visually crossing through
-- each other)?
--
-- Prompt: docs/agent-prompts/10-continue.md, action 1.
--
-- The mesh draws a rest point p at p + D(p). That map is a graph only while its
-- horizontal Jacobian
--
--     J = [ 1 + dDx/dx   dDx/dz ]
--         [   dDz/dx   1 + dDz/dz ]
--
-- has a positive determinant. Where det J <= 0 the map folds: two rest points
-- land on the same world XZ, triangles invert, and the render shows the waves
-- crossing / cusps tearing.
--
-- This computes J by FINITE DIFFERENCES on the real `Gerstner.ComputeTransform`,
-- not from a hand-derived formula. (A hand-derived version of this file was
-- wrong on the first attempt: it multiplied an extra amplitude factor into the
-- displacement term, which inflated the folding estimate by 1.3-2.4x and made a
-- harmless zone look broken. The shipped function cannot lie about its own
-- derivatives.)
--
-- Assembled and run by: bash tools/measure/jacobian.sh

local H = 0.05 -- finite-difference step, studs
local FPS = 60

-- Sample times spread across the sea-state field's ~10 min period.
local TIMES = { 0, 37.5, 137.25, 411.0, 703.5 }

local function detJ(p, t, amp, speed, phase)
	local d0 = Gerstner.ComputeTransform(SETTINGS_STUB.Waves, p, t, phase, speed, amp)
	local px = Gerstner.ComputeTransform(SETTINGS_STUB.Waves, Vector3.new(p.X + H, p.Y, p.Z), t, phase, speed, amp)
	local pz = Gerstner.ComputeTransform(SETTINGS_STUB.Waves, Vector3.new(p.X, p.Y, p.Z + H), t, phase, speed, amp)

	local j11 = 1 + (px.X - d0.X) / H
	local j21 = (px.Z - d0.Z) / H
	local j12 = (d0.X - px.X) / H
	j12 = (pz.X - d0.X) / H
	local j22 = 1 + (pz.Z - d0.Z) / H
	local j21b = (px.Z - d0.Z) / H

	return j11 * j22 - j12 * j21b, j11, j22
end

-- Cross-check the finite-difference Jacobian against the classic Q-sum rule:
-- horizontal displacement of wave i is dir.x*A*cos(phi), so d/dx is
-- -Q_i*dir.x^2*sin(phi) with Q_i the steepness. With a uniform amplitude
-- multiplier m the bound is  m * sum(Q_i) <= 1.
local function analyticDet(p, t, amp, speed, phase)
	local j11, j12, j22 = 1, 0, 1
	local seaState = Gerstner.SeaStateAt(p, t)
	for _, W in ipairs(SETTINGS_STUB.Waves) do
		local k = W.WaveNumber * phase
		local c = W.WaveSpeed * speed
		local ph = k * (W.Direction:Dot(p) - c * t)
		local term = amp * seaState * W.Steepness * math.sin(ph)
		local dx, dz = W.Direction.X, W.Direction.Z
		j11 -= term * dx * dx
		j12 -= term * dx * dz
		j22 -= term * dz * dz
	end
	return j11 * j22 - j12 * j12
end

local function scan(label, seaState, amp, speed, phase, grid, extent)
	local saved = Gerstner.SeaStateAt
	if seaState then
		Gerstner.SeaStateAt = function()
			return seaState
		end
	end
	local worst, worstAt, worstT = math.huge, nil, nil
	local folds, total = 0, 0
	local maxAnalyticGap = 0
	for _, t in ipairs(TIMES) do
		for i = 0, grid do
			for j = 0, grid do
				local p = Vector3.new((i / grid - 0.5) * 2 * extent, 0, (j / grid - 0.5) * 2 * extent)
				local det = detJ(p, t, amp or 1, speed or 1, phase or 1)
				local ana = analyticDet(p, t, amp or 1, speed or 1, phase or 1)
				local gap = math.abs(det - ana)
				if gap > maxAnalyticGap then
					maxAnalyticGap = gap
				end
				total += 1
				if det < worst then
					worst = det
					worstAt = { x = p.X, z = p.Z }
					worstT = t
				end
				if det <= 0 then
					folds += 1
				end
			end
		end
	end
	Gerstner.SeaStateAt = saved
	print(string.format(
		"%-38s min detJ=%+.6f  folds=%d/%d (%.1f%%)  |numeric-analytic|max=%.2e",
		label, worst, folds, total, folds / total * 100, maxAnalyticGap
	))
	if folds > 0 then
		print(string.format("    worst at x=%.1f z=%.1f t=%.2f", worstAt.x, worstAt.z, worstT))
	end
	return worst, folds / total
end

print("")
print("=== Does the displaced ocean surface fold over itself? ===")
print("Finite differences on the real ComputeTransform. det J > 0 = a valid surface.")
print("A sanity check prints |numeric - analytic| so the two methods agree.")
print("")

print("--- shipped sea states, no zone")
scan("calm  (SeaState 0.30)", Gerstner.SEA_STATE_CALM, 1, 1, 1, 120, 1000)
scan("rough (SeaState 1.00)", 1.0, 1, 1, 1, 120, 1000)
scan("live sea-state field", nil, 1, 1, 1, 120, 1000)

print("")
print("--- uniform amplitude multiplier m (what a zone does to the whole field)")
for _, m in ipairs({ 1.0, 1.2, 1.3, 1.4, 1.45, 1.5, 1.75, 2.0, 2.5 }) do
	scan(string.format("  amplitude x%.2f", m), 1.0, m, 1, 1, 90, 1000)
end

print("")
print("--- the shipped RoughSea zone: Radius 300, AmplitudeMultiplier 2.5,")
print("    SpeedMultiplier 1.1, PhaseMultiplier 0.75, falloff 1 + 1.5*(1-d/R)")
local R = 300
local function scanZoneDisc(grid, tList)
	local folds, total = 0, 0
	local worst = math.huge
	for _, t in ipairs(tList) do
		for i = 0, grid do
			for j = 0, grid do
				local u, v = (i / grid) * 2 - 1, (j / grid) * 2 - 1
				if u * u + v * v <= 1 then
					local d = math.sqrt(u * u + v * v) * R
					local amp = 1 + (2.5 - 1) * (1 - d / R)
					local p = Vector3.new(u * R, 0, v * R)
					local det = detJ(p, t, amp, 1.1, 0.75)
					total += 1
					if det <= 0 then
						folds += 1
					end
					if det < worst then
						worst = det
					end
				end
			end
		end
	end
	return folds / total, worst
end
Gerstner.SeaStateAt = function()
	return 1.0
end
local zf, zw = scanZoneDisc(150, TIMES)
print(string.format("  at sea state 1.00: folded area %.2f%% of the zone disc, min detJ=%+.6f", zf * 100, zw))
Gerstner.SeaStateAt = function()
	return Gerstner.SEA_STATE_CALM
end
local zfc, zwc = scanZoneDisc(150, TIMES)
print(string.format("  at sea state 0.30: folded area %.2f%% of the zone disc, min detJ=%+.6f", zfc * 100, zwc))

print("")
print("--- how much of the sea the RoughSea zone covers")
print(string.format("  Radius %d -> %.0f sq studs of %d zones", R, math.pi * R * R, 1))
print("")
print("verdict is read off the fold counts above; see docs/audit/04-seam-zones.md")
print("")

RESULT = "ok"
