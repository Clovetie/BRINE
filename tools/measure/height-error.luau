--!nocheck
-- Measures the height error between the ocean a player SEES and the height
-- physics READS, by calling the shipped `WaveFloat.HeightAt` itself.
--
-- Prompt 02, suspect S2. See docs/audit/02-waves-findings.md.
--
-- Why an error exists at all: the mesh draws every vertex at `rest + D(rest)`,
-- a full Gerstner displacement with the horizontal part included. Physics asks
-- "how high is the water at world XZ?" and, before the fix, answered
-- `PLANE_Y + D(worldXZ).Y` - evaluating the wave at the query point as if it
-- were a rest point. The visible surface above that XZ belongs to a different
-- rest point, so the two differ by (local slope x horizontal shift).
--
-- Ground truth here is the preimage rest point, solved to convergence
-- (24 fixed-point steps, residual < 1e-6). Every row uses the SAME 100 points.
--
-- Assembled and run by: bash tools/measure-height-error.sh

-- The wave table was installed by stubs.luau before WaveFloat loaded.
local Waves = SETTINGS_STUB.Waves

local RealSeaStateAt = Gerstner.SeaStateAt
local T0 = 137.25
local PLANE_Y = SETTINGS_STUB.GRID_SETTINGS.PLANE_OFFSET.Y

local SEED0 = 20261026
local seed = SEED0
local function rand()
	seed = (1103515245 * seed + 12345) % 2147483648
	return seed / 2147483648
end

local function percentile(sorted, p)
	local i = math.clamp(math.floor(p * (#sorted - 1) + 0.5) + 1, 1, #sorted)
	return sorted[i]
end

-- The rest point that lands on `world`, converged hard: this is what the mesh
-- actually shows above that world XZ.
local function restOf(world)
	local r = Vector3.new(world.X, 0, world.Z)
	for _ = 1, 24 do
		local d = Gerstner.ComputeTransform(Waves, r, T0)
		r = Vector3.new(world.X - d.X, 0, world.Z - d.Z)
	end
	return r
end

local function run(label, steps)
	seed = SEED0 -- identical points for every row
	WaveFloat.INVERSE_STEPS = steps

	local errors, shifts = {}, {}
	local sumShift = 0
	for _ = 1, 100 do
		local world = Vector3.new((rand() - 0.5) * 1600, PLANE_Y, (rand() - 0.5) * 1600)

		local rest = restOf(world)
		local truth = PLANE_Y + Gerstner.ComputeTransform(Waves, rest, T0).Y

		-- The shipped function:
		local read = WaveFloat.HeightAt(world, nil, "ANALYTIC", nil, T0)

		local shift = math.sqrt((world.X - rest.X) ^ 2 + (world.Z - rest.Z) ^ 2)
		table.insert(errors, math.abs(truth - read))
		table.insert(shifts, shift)
		sumShift += shift
	end
	table.sort(errors)

	local mean = 0
	for _, e in ipairs(errors) do
		mean += e
	end
	mean = mean / #errors

	print(string.format(
		"  %-28s mean=%6.4f  p50=%6.4f  p95=%6.4f  p99=%6.4f  max=%6.4f   meanXZshift=%.3f p99XZshift=%.3f",
		label,
		mean,
		percentile(errors, 0.50),
		percentile(errors, 0.95),
		percentile(errors, 0.99),
		errors[#errors],
		sumShift / #shifts,
		percentile(shifts, 0.99)
	))
	return percentile(errors, 0.99), errors[#errors]
end

print("")
print("=== Physics-vs-mesh height error via the shipped WaveFloat.HeightAt ===")
print("100 points, t=" .. T0 .. ", PLANE_Y=" .. PLANE_Y .. ". Calm = SeaState 0.30")
print("(the SEA_STATE_CALM floor), rough = 1.00. INVERSE_STEPS=0 is the old code.")
print("")

local cases = {
	{ "calm  (seastate 0.30)", Gerstner.SEA_STATE_CALM },
	{ "rough (seastate 1.00)", 1.0 },
	{ "live sea-state field", nil },
}
local verdicts = {}
for _, c in ipairs(cases) do
	local label, state = c[1], c[2]
	if state == nil then
		Gerstner.SeaStateAt = RealSeaStateAt
	else
		Gerstner.SeaStateAt = function()
			return state
		end
	end
	print("--- " .. label)
	local bP99 = run("before (INVERSE_STEPS=0)", 0)
	local a2 = run("after  (INVERSE_STEPS=2)", 2)
	local a3P99 = run("after  (INVERSE_STEPS=3)", 3)
	run("after  (INVERSE_STEPS=4)", 4)
	verdicts[#verdicts + 1] = { label = label, before = bP99, after = a3P99, a2 = a2 }
	print("")
end
Gerstner.SeaStateAt = RealSeaStateAt

print("A1: p99 <= 0.100 studs")
for _, v in ipairs(verdicts) do
	print(string.format(
		"  %-22s before p99=%7.4f %s | K=3 p99=%7.4f %s",
		v.label,
		v.before,
		v.before <= 0.1 and "PASS" or "FAIL",
		v.after,
		v.after <= 0.1 and "PASS" or "FAIL"
	))
end

-- ---------------------------------------------------------------------------
-- Cost: HeightAt evaluations per second, before vs after. This is pure-Luau
-- relative cost in a headless VM, NOT a Roblox frame time; use it to see the
-- size of the change, then confirm in Studio (prompt 03).
-- ---------------------------------------------------------------------------
print("")
local COST_N = 200000
local function cost(label, steps)
	WaveFloat.INVERSE_STEPS = steps
	local x = Vector3.new(120.5, PLANE_Y, -333.25)
	-- warm up
	for _ = 1, 1000 do
		WaveFloat.HeightAt(x, nil, "ANALYTIC", nil, T0)
	end
	local t0 = os.clock()
	local acc = 0
	for _ = 1, COST_N do
		acc += WaveFloat.HeightAt(x, nil, "ANALYTIC", nil, T0)
	end
	local dt = os.clock() - t0
	print(string.format(
		"  %-26s %8.0f HeightAt/s   (%.3f us each)   guard=%s",
		label,
		COST_N / dt,
		dt / COST_N * 1e6,
		acc == acc and "ok" or "nan"
	))
	return dt
end
print("--- cost (headless Luau VM, relative only; same point, no zones)")
local d0 = cost("INVERSE_STEPS=0 (old)", 0)
local d3 = cost("INVERSE_STEPS=3 (new)", 3)
local d2 = cost("INVERSE_STEPS=2", 2)
print(string.format("  K=3 is %.2fx the cost of the old read; K=2 is %.2fx", d3 / d0, d2 / d0))
print("")

RESULT = "ok"
