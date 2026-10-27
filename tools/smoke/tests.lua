-- tests.lua
-- Smoke tests for the FloatingObjectGeneration modules, executed inside the
-- fengari mock environment. SOURCES / luauRequire are injected by
-- tools/smoke-test.js together with roblox-mocks.lua.

local Vector3 = MOCKS.Vector3
local CFrame = MOCKS.CFrame
local newInstance = MOCKS.newInstance
local Workspace = MOCKS.Workspace
local ReplicatedStorage = MOCKS.ReplicatedStorage
local ServerStorage = MOCKS.ServerStorage
local Players = MOCKS.Players
local pumpFrames = MOCKS.pumpFrames

TESTS = { passed = 0, failed = 0 }
local function check(cond, msg)
	if cond then
		TESTS.passed += 1
		print("PASS  " .. msg)
	else
		TESTS.failed += 1
		warn("FAIL  " .. msg)
	end
end

BUOY_CALLS = 0
LOOKUP_CALLS = 0
GERSTNER_CALLS = 0
LOOKUP_FAIL = false

-- ---------------------------------------------------------------------------
-- Mock module graph
-- ---------------------------------------------------------------------------
local function makeOctreeStub()
	local M = {}
	function M.new()
		local o = { nodes = {} }
		function o:CreateNode(position, object)
			local node = { Position = position, Object = object }
			table.insert(o.nodes, node)
			return node
		end
		function o:RemoveNode(node)
			for i, n in ipairs(o.nodes) do
				if n == node then
					table.remove(o.nodes, i)
					break
				end
			end
		end
		function o:SearchRadius(position, radius)
			local out = {}
			for _, n in ipairs(o.nodes) do
				local dx = n.Position.X - position.X
				local dy = n.Position.Y - position.Y
				local dz = n.Position.Z - position.Z
				if math.sqrt(dx * dx + dy * dy + dz * dz) < radius then
					table.insert(out, n)
				end
			end
			return out
		end
		function o:ClearAllNodes()
			o.nodes = {}
		end
		return o
	end
	return M
end

local octreeStub = makeOctreeStub()

local islandTree = octreeStub.new()
islandTree:CreateNode(Vector3.new(1200, 25, 1200), {
	Island = newInstance("Model", "FakeIsland"),
	Radius = 300,
})

local ZoneManagerMock = {
	ISLAND_TREE = islandTree,
	GetZoneParameters = function()
		return nil
	end,
	GetZoneMultipliers = function()
		return 1, 1, 1, true
	end,
	GetIslandMultipliers = function()
		return 1, 1, 1, true, 0
	end,
}

local BoatManagerMock = {
	CalculateBuoyancy = function(centerOfMass, bottom, points, length, width, height, zoneInfo)
		BUOY_CALLS += 1
		return Vector3.new(0, 25 + 1.5 + height, 0), CFrame.fromEulerAnglesXYZ(0.02, 0, -0.01), 0.3
	end,
}

local HeightLookupMock = {
	Lookup = function(point)
		LOOKUP_CALLS += 1
		if LOOKUP_FAIL then
			return -1 -- exactly what the real module returns when it cannot resolve
		end
		return 25 + math.sin(point.X * 0.01) * 0.9
	end,
}

-- Waves shaped like the real Settings.Waves entries (Direction / WaveNumber /
-- WaveSpeed / WaveAmplitude), so the mock surface actually moves.
local function mockWave(dx, dz, waveLength, steepness)
	local waveNumber = 2 * math.pi / waveLength
	return {
		Direction = Vector3.new(dx, 0, dz),
		WaveLength = waveLength,
		Steepness = steepness,
		WaveNumber = waveNumber,
		WaveSpeed = math.sqrt(9.8 / waveNumber),
		WaveAmplitude = steepness / waveNumber,
	}
end

local mockWaves = {
	mockWave(0.6, 0.05, 24, 0.6),
	mockWave(0.2, 0.4, 28, 0.4),
	mockWave(0.15, 0.1, 35, 0.35),
}

-- Same summed Y as Gerstner.ComputeWave, which is the height the ocean mesh is
-- displaced with. WaveFloat's ANALYTIC source samples this, so the tests below
-- exercise a moving wave field instead of a constant.
local GerstnerMock = {}
function GerstnerMock.ComputeTransform(waveList, point, t, phaseMulti, speedMulti, amplitudeMulti)
	GERSTNER_CALLS += 1
	local y = 0
	for _, wave in ipairs(waveList) do
		local k = wave.WaveNumber * (phaseMulti or 1)
		local c = wave.WaveSpeed * (speedMulti or 1)
		local a = wave.WaveAmplitude * (amplitudeMulti or 1)
		local phase = k * (wave.Direction.X * point.X + wave.Direction.Z * point.Z - c * t)
		y = y + a * math.sin(phase)
	end
	return Vector3.new(0, y, 0)
end
function GerstnerMock.GetVortexTransform(zone)
	return Vector3.new(0, -(zone.DownwardForce or 4), 0), Vector3.new(0, 0, 0)
end

local SettingsMock = {
	GRID_SETTINGS = { PLANE_OFFSET = Vector3.new(0, 25, 0) },
	Waves = mockWaves,
}

-- ---------------------------------------------------------------------------
-- Instance trees (ServerStorage templates + ReplicatedStorage modules)
-- ---------------------------------------------------------------------------
local templatesRoot = newInstance("Folder", "FloatingObjects")
templatesRoot.Parent = ServerStorage

local propsFolder = newInstance("Folder", "Props")
propsFolder.Parent = templatesRoot

local function makePart(name, size, mass)
	local part = newInstance("Part", name)
	part.Size = size
	part.CFrame = CFrame.new(0, 0, 0)
	part.Anchored = true
	part.AssemblyMass = mass or 5
	return part
end

local crate = newInstance("Model", "Crate")
makePart("Body", Vector3.new(3, 3, 3), 5).Parent = crate
crate.PrimaryPart = crate:FindFirstChild("Body")
crate._tags.Small = true
crate.Parent = propsFolder

local wreck = newInstance("Model", "Wreck")
makePart("Hull", Vector3.new(14, 4, 30), 60).Parent = wreck
makePart("Mast", Vector3.new(1, 12, 1), 8).Parent = wreck
wreck._tags.Large = true
wreck.Parent = propsFolder

local plank = makePart("Plank", Vector3.new(6, 0.5, 1), 2)
plank._tags.Debris = true
plank.Parent = propsFolder

local raft = newInstance("Model", "Raft")
makePart("Deck", Vector3.new(8, 1, 8), 20).Parent = raft
raft:SetAttribute("FloatRatio", 0.8)
raft._tags.Medium = true
raft.Parent = propsFolder

local mystery = newInstance("Model", "Mystery") -- untagged -> skipped + warned
makePart("Body", Vector3.new(2, 2, 2), 2).Parent = mystery
mystery.Parent = templatesRoot

local gerstner = newInstance("Folder", "Gerstner")
gerstner.Parent = ReplicatedStorage
local settingsInst = newInstance("ModuleScript", "Settings")
settingsInst.Parent = gerstner
local seedValue = newInstance("IntValue", "Seed")
seedValue.Value = 424242
seedValue.Parent = settingsInst
local heightLookupInst = newInstance("ModuleScript", "HeightLookup")
heightLookupInst.Parent = gerstner
local serial = newInstance("Folder", "Serial")
serial.Parent = gerstner
local boatManagerInst = newInstance("ModuleScript", "BoatManager")
boatManagerInst.Parent = serial
local zoneManagerInst = newInstance("ModuleScript", "ZoneManager")
zoneManagerInst.Parent = serial
local octreeInst = newInstance("ModuleScript", "Octree")
octreeInst.Parent = ReplicatedStorage

local islandGenFolder = newInstance("Folder", "IslandGeneration")
islandGenFolder.Parent = ReplicatedStorage
local densityInst = newInstance("ModuleScript", "Density")
densityInst.Parent = islandGenFolder

local fogFolder = newInstance("Folder", "FloatingObjectGeneration")
fogFolder.Parent = ReplicatedStorage
local configInst = newInstance("ModuleScript", "FloatingObjectConfig")
configInst.Parent = fogFolder
local generatorInst = newInstance("ModuleScript", "FloatingObjectGenerator")
generatorInst.Parent = fogFolder
local waveFloatInst = newInstance("ModuleScript", "WaveFloat")
waveFloatInst.Parent = fogFolder
local cameraReportInst = newInstance("RemoteEvent", "CameraReport")
cameraReportInst.Parent = fogFolder

-- ---------------------------------------------------------------------------
-- require()
-- ---------------------------------------------------------------------------
local MODULES = {}
MODULES[settingsInst] = { loaded = SettingsMock }
MODULES[heightLookupInst] = { loaded = HeightLookupMock }
MODULES[boatManagerInst] = { loaded = BoatManagerMock }
MODULES[zoneManagerInst] = { loaded = ZoneManagerMock }
MODULES[octreeInst] = { loaded = octreeStub }
MODULES[gerstner] = { loaded = GerstnerMock }
MODULES[waveFloatInst] = { source = "WaveFloat" }
MODULES[configInst] = { source = "FloatingObjectConfig" }
MODULES[generatorInst] = { source = "FloatingObjectGenerator" }
MODULES[densityInst] = { source = "Density" }

function luauRequire(inst)
	local entry = MODULES[inst]
	if not entry then
		error("luauRequire: unknown module instance " .. tostring(inst and inst.Name), 0)
	end
	if entry.loaded then
		return entry.loaded
	end
	local source = SOURCES[entry.source]
	if not source then
		error("luauRequire: no source registered for " .. entry.source, 0)
	end
	local env = setmetatable({ script = inst, require = luauRequire }, { __index = _G })
	local chunk, err = load(source, "=" .. entry.source, "t", env)
	if not chunk then
		error("luauRequire: load failed for " .. entry.source .. ": " .. tostring(err), 0)
	end
	local ok, result = pcall(chunk)
	if not ok then
		error("luauRequire: run failed for " .. entry.source .. ": " .. tostring(result), 0)
	end
	entry.loaded = result
	return result
end

-- ---------------------------------------------------------------------------
-- Fake player
-- ---------------------------------------------------------------------------
local player = { Name = "Tester", ClassName = "Player" }
local character = newInstance("Model", "Tester")
local humanoid = newInstance("Humanoid", "Humanoid")
humanoid.Health = 100
humanoid.Parent = character
local rootPart = makePart("HumanoidRootPart", Vector3.new(2, 2, 1), 8)
rootPart.CFrame = CFrame.new(500, 25, 500)
rootPart.Parent = character
character.Parent = Workspace
player.Character = character
Players._players[1] = player

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------
local Gen = luauRequire(generatorInst)
local Config = luauRequire(configInst)
-- The buoyancy checks park the player on a rig. The placement ring
-- (Streaming.MinPlayerDistance) keeps objects this close uncached, so the
-- buoyancy checks run with the ring off. Section 18 covers the ring itself.
Config.Streaming.MinPlayerDistance = 0

-- 1. Catalog discovery + tag classification
local catalog = Gen.GetCatalog()
check(catalog.Small ~= nil and catalog.Small.templateCount == 1, "catalog: Small pool has the Crate")
check(catalog.Medium ~= nil and catalog.Medium.templateCount == 1, "catalog: Medium pool has the Raft")
check(catalog.Large ~= nil and catalog.Large.templateCount == 1, "catalog: Large pool has the Wreck")
check(catalog.Debris ~= nil and catalog.Debris.templateCount == 1, "catalog: Debris pool has the Plank")
check(catalog.Mystery == nil, "catalog: untagged template skipped")

-- 2. Generate + streaming + rendering + buoyancy
Gen.Generate()
pumpFrames(10)

local stats = Gen.GetStats()
check(stats.Streaming == true, "streaming loop is running")
check(stats.CachedCells > 0, "cells were cached around the player")
check(stats.RenderedObjects > 0, "objects were rendered near the player")
check(stats.RenderedObjects <= stats.MaxRenderedObjects, "rendered count within cap")
check(stats.BuoyantObjects > 0, "some objects are simulating buoyancy")

local container = Workspace:FindFirstChild("_FloatingObjects")
check(container ~= nil, "workspace._FloatingObjects container exists")
check(#container:GetChildren() == stats.RenderedObjects, "container children match rendered record count")

local sawAlignTarget = false
local allTagged = true
for _, model in container:GetChildren() do
	if not MOCKS.CollectionService:HasTag(model, "FloatingObject") then
		allTagged = false
	end
	for _, desc in model:GetDescendants() do
		if desc.Name == "FloatingBuoyancy" and desc.Position ~= nil then
			sawAlignTarget = true
		end
	end
end
check(allTagged, "rendered clones are tagged FloatingObject")
check(sawAlignTarget, "buoyancy scheduler set AlignPosition.Position")
-- The ANALYTIC source samples the Gerstner surface directly (no mesh, works on
-- the server too); "MESH" is the opt-in parity path that hits HeightLookup.
check(GERSTNER_CALLS > 0, "wave heights were sampled from the water surface")


-- 3. Camera-based caching: near but unseen -> cached after grace
local victim = container:GetChildren()[1]
check(victim ~= nil, "a rendered object exists for the camera test")
if victim ~= nil then
	local victimPos = victim:GetPivot().Position
	rootPart.CFrame = CFrame.new(victimPos.X + 400, 25, victimPos.Z)
	-- Camera 1000 studs past the player, looking further AWAY from the
	-- object. Real clients re-report ~2x/second, so keep it fresh while
	-- pumping past the 3s out-of-view grace.
	local camPos = Vector3.new(victimPos.X + 400, 30, victimPos.Z + 1000)
	local camLook = Vector3.new(0, 0, 1)
	for _ = 1, 25 do
		Gen.SetCameraState(player, camPos, camLook)
		pumpFrames(0.4)
	end
	check(victim.Parent == nil or victim._destroyed == true, "out-of-view object cached after grace period")
end

-- 4. Distance-only fallback (no fresh camera): middle-band stays Frozen
rootPart.CFrame = CFrame.new(-900, 25, -900)
pumpFrames(14)
local s2 = Gen.GetStats()
check(s2.RenderedObjects > 0, "distance-only fallback keeps nearby objects rendered")
check(s2.FrozenObjects > 0, "middle-band objects freeze without camera data")

-- 5. No players -> everything caches
Players._players[1] = nil
pumpFrames(20)
local s3 = Gen.GetStats()
check(s3.RenderedObjects == 0, "all objects cached when no players remain")

-- 6. Hard cap
Config.Streaming.MaxRenderedObjects = 5
Players._players[1] = player
rootPart.CFrame = CFrame.new(-900, 25, -900)
pumpFrames(12)
local s4 = Gen.GetStats()
check(s4.RenderedObjects <= 5, "render cap of 5 respected")
Config.Streaming.MaxRenderedObjects = 500

-- 7. PlaceOne debug API
local placed = Gen.PlaceOne(Vector3.new(2500, 25, 2500), "Debris")
check(placed ~= nil and placed.Parent ~= nil, "PlaceOne spawns a Debris object at a clear spot")
check(placed:FindFirstChildWhichIsA("BasePart", true) ~= nil, "PlaceOne model has parts")

-- 8. Camera report validation (bad input must be ignored, not crash)
Gen.SetCameraState(player, "not-a-vector", Vector3.new(0, 0, 1))
Gen.SetCameraState(player, Vector3.new(0, 0, 0), Vector3.zero)
Gen.SetCameraState(player, Vector3.new(0 / 0, 0 / 0, 0 / 0), Vector3.new(0 / 0, 0 / 0, 0 / 0))
check(true, "SetCameraState rejects invalid payloads without crashing")

-- 9. External removal resilience
rootPart.CFrame = CFrame.new(-900, 25, -900)
pumpFrames(8)
local kids = container:GetChildren()
check(#kids > 0, "objects re-rendered around the returning player")
if #kids > 0 then
	kids[1]:Destroy()
	pumpFrames(3)
	local s5 = Gen.GetStats()
	check(
		#container:GetChildren() == s5.RenderedObjects,
		"stats stay consistent after an externally destroyed model"
	)
end

-- 10. Clear + regenerate
Gen.ClearGenerated()
check(#container:GetChildren() == 0, "ClearGenerated empties the container")
check(Gen.GetStats().RenderedObjects == 0, "ClearGenerated zeroes rendered stats")
Gen.Generate()
pumpFrames(10)
check(Gen.GetStats().RenderedObjects > 0, "Generate() restarts streaming after ClearGenerated()")

-- 11. Missing templates root
Gen.ClearGenerated()
Config.TemplatesRoot = "DoesNotExist"
Gen.Generate()
pumpFrames(3)
check(true, "missing templates root handled without crashing")
Config.TemplatesRoot = "FloatingObjects"
pumpFrames(3) -- let the catalog retry throttle elapse
Gen.Generate()
pumpFrames(2)

-- 12. Island avoidance: sail right up to the seeded island footprint
rootPart.CFrame = CFrame.new(1500, 25, 1500)
pumpFrames(12)
local nearIslandCount = 0
local insideIsland = false
for _, model in container:GetChildren() do
	local p = model:GetPivot().Position
	local dx, dz = p.X - 1200, p.Z - 1200
	local dist = math.sqrt(dx * dx + dz * dz)
	if dist < 300 then
		insideIsland = true
	elseif dist < 1200 then
		nearIslandCount += 1
	end
end
check(insideIsland == false, "no object generated inside the island footprint")
check(nearIslandCount > 0, "objects still generate in open water near the island")

	-- 13. Ship-parity buoyancy rig ------------------------------------------------
-- Bring the player back so objects near them stay in the sim band.
rootPart.CFrame = CFrame.new(-900, 25, -900)
pumpFrames(8)

-- Closest actively-buoyant model to a point, optionally requiring a minimum
-- bounding-box height. The tall variants matter for the tests below: the mock
-- has no physics, so a 2-stud plank parked at its spawn height can end up
-- riding above a wave crest and (correctly) go airborne, which would make
-- assertions about written goals flaky. A wreck with a 12-stud hull stays
-- engaged.
local function buoyantModelNear(pos, minBBoxY)
	local best, bestDist = nil, math.huge
	for _, model in container:GetChildren() do
		local alignPos = model:FindFirstChildWhichIsA("AlignPosition", true)
		local primary = model.PrimaryPart
		if alignPos and alignPos.Enabled and primary and primary.Parent then
			local _, bboxSize = model:GetBoundingBox()
			if (bboxSize == nil or bboxSize.Y >= (minBBoxY or 0)) then
				local d = (primary.Position - pos).Magnitude
				if d < bestDist then
					bestDist, best = d, model
				end
			end
		end
	end
	return best
end

local rig = buoyantModelNear(rootPart.Position, 6)
check(rig ~= nil, "a buoyant object is simulating next to a player")
if rig then
	-- Park the player on it: the near band and the sim band are both distance
	-- driven and only re-decided by the streaming cycle, so the cadence and
	-- goal assertions below need a player actually next to the rig.
	rootPart.CFrame = CFrame.new(rig.PrimaryPart.Position.X, 25, rig.PrimaryPart.Position.Z)
	pumpFrames(2)
end
local rigHull = rig and rig.PrimaryPart
local rigAlignPos = rig and rig:FindFirstChildWhichIsA("AlignPosition", true)

if rig and rigHull then
	local corners = { FloatTopLeft = 0, FloatTopRight = 0, FloatBottomLeft = 0, FloatBottomRight = 0 }
	local named = {}
	local moverLocal, waterlineLocal
	for _, desc in rigHull:GetChildren() do
		if desc.ClassName == "Attachment" then
			if corners[desc.Name] ~= nil then
				corners[desc.Name] += 1
			end
			named[desc.Name] = true
			if desc.Name == "FloatingMover" then
				moverLocal = desc.CFrame
			elseif desc.Name == "FloatingWaterline" then
				waterlineLocal = desc.CFrame
			end
		end
	end
	check(
		corners.FloatTopLeft == 1
			and corners.FloatTopRight == 1
			and corners.FloatBottomLeft == 1
			and corners.FloatBottomRight == 1,
		"buoyant objects are rigged with 4 surface sample attachments (small props included)"
	)
	check(named.FloatingWaterline == true, "the rig carries a hull-bottom waterline reference")

	-- Depth must be measured at the BOTTOM of the hull. Measuring it at the
	-- bounding-box centre (the old behaviour) reads "clear air under the keel"
	-- on any tall template, which switched the servo off and let the object
	-- free-fall out of the ocean.
	local _, rigBBox = rig:GetBoundingBox()
	check(
		moverLocal ~= nil
			and waterlineLocal ~= nil
			and (moverLocal.Position - waterlineLocal.Position).Magnitude
			>= (rigBBox and rigBBox.Y or 0) * 0.4,
		"the waterline reference sits at the hull bottom, not the bbox centre"
	)

	-- The ship uses per-axis limits so buoyancy cannot act sideways.
	check(
		rigAlignPos.ForceLimitMode == Enum.ForceLimitMode.PerAxis
			and rigAlignPos.ForceRelativeTo == Enum.ActuatorRelativeTo.World,
		"AlignPosition limits force per world axis"
	)
	local axes = rigAlignPos.MaxAxesForce
	local driftShare = Config.Buoyancy.DriftReturnForce or 0
	check(
		axes ~= nil
			and axes.Y > 0
			and math.abs(axes.X - axes.Y * driftShare) < 0.01
			and axes.X == axes.Z
			and axes.X < axes.Y * 0.5,
		"buoyancy is vertical-only apart from the small DriftReturnForce share"
	)

	-- Attitude: the wave field is sloped, so the four corner heights differ and
	-- the commanded frame must lean off vertical.
	local tilted = false
	for _, model in container:GetChildren() do
		local ao = model:FindFirstChildWhichIsA("AlignOrientation", true)
		local ap = model:FindFirstChildWhichIsA("AlignPosition", true)
		if ao and ap and ap.Enabled and ao.CFrame then
			local up = ao.CFrame.UpVector
			if up and up.X * up.X + up.Z * up.Z > 1e-6 then
				tilted = true
				break
			end
		end
	end
	check(tilted, "objects are commanded to tilt with the wave slope instead of sitting level")

	-- Analytic sampling: heights come from the Gerstner surface the ocean mesh is
	-- displaced with, which needs no mesh and works on the server and client.
	check(GERSTNER_CALLS > 0, "wave heights are sampled from the Gerstner surface")
end

-- 14. Cadence: near band every frame, everyone else on a shared clock --------
local function distinctGoals(model, frames)
	local alignPos = model:FindFirstChildWhichIsA("AlignPosition", true)
	local seen, count = {}, 0
	for _ = 1, frames do
		pumpFrames(1 / 60, 1 / 60)
		local y = alignPos and alignPos.Position and alignPos.Position.Y
		if y then
			local key = string.format("%.6f", y)
			if not seen[key] then
				seen[key] = true
				count += 1
			end
		end
	end
	return count
end

if rig then
	local nearCount = distinctGoals(rig, 30) -- 0.5 s at 60 fps, near band armed
	Config.Buoyancy.NearDistance = 0
	pumpFrames(2) -- the streaming cycle re-decides the band, not the float loop
	local pacedCount = distinctGoals(rig, 30) -- same object, staggered clock only
	Config.Buoyancy.NearDistance = 150
	pumpFrames(2)
	check(
		nearCount >= 20,
		"objects inside NearDistance get a fresh goal every frame (got " .. tostring(nearCount) .. "/30)"
	)
	check(
		pacedCount * 3 < nearCount,
		"everything else rides the staggered UpdateInterval clock (got "
			.. tostring(pacedCount)
			.. "/30)"
	)
end

-- 15. Drift return: the XZ goal is the prop's own patch of ocean -------------
if rigAlignPos and rigHull then
	local drift = Config.Buoyancy.DriftReturnForce
	pumpFrames(0.3)
	local heldX = rigAlignPos.Position.X
	rigHull.CFrame = CFrame.new(rigHull.Position + Vector3.new(60, 0, 0)) -- shove it
	pumpFrames(0.3)
	check(
		math.abs(rigAlignPos.Position.X - heldX) < 0.5,
		"a pushed object is still driven back toward its own column"
	)
	Config.Buoyancy.DriftReturnForce = 0
	pumpFrames(0.3)
	local freeAxes = rigAlignPos.MaxAxesForce
	check(
		freeAxes.X == 0 and freeAxes.Z == 0,
		"DriftReturnForce = 0 leaves the servo no horizontal authority at all"
	)
	check(
		math.abs(rigAlignPos.Position.X - heldX) > 5,
		"with drift return off, the goal tracks the pushed object instead of home"
	)
	Config.Buoyancy.DriftReturnForce = drift
	rigHull.CFrame = CFrame.new(rigHull.Position - Vector3.new(60, 0, 0))
	pumpFrames(0.3)
end

-- 16. MESH height source, and what a failed lookup must NOT do --------------
if rig then
	local lookupBefore = LOOKUP_CALLS
	Config.Buoyancy.HeightSource = "MESH"
	pumpFrames(0.5)
	check(
		LOOKUP_CALLS > lookupBefore,
		"HeightSource=MESH samples HeightLookup exactly like the ship does"
	)
	local alignPos = rig:FindFirstChildWhichIsA("AlignPosition", true)
	local wasEnabled = alignPos.Enabled
	local lastGoal = alignPos.Position
	LOOKUP_FAIL = true
	pumpFrames(0.5)
	check(
		alignPos.Enabled == wasEnabled
			and alignPos.Position.X == lastGoal.X
			and alignPos.Position.Y == lastGoal.Y,
		"a failed mesh lookup keeps the previous goal instead of dropping the object"
	)
	LOOKUP_FAIL = false
	Config.Buoyancy.HeightSource = "ANALYTIC"
	pumpFrames(0.5)
	check(alignPos.Enabled, "the object is still riding the wave after the lookup recovered")
end

-- 17. Network ownership is opt-in, capped, and released ---------------------
if rigHull then
	check(rigHull.NetworkOwner == nil, 'default Buoyancy.Ownership = "Server" keeps ownership')
	Config.Buoyancy.Ownership = "NearestPlayer"
	pumpFrames(3)
	local owned = 0
	for _, model in container:GetChildren() do
		local primary = model.PrimaryPart
		if primary and primary.NetworkOwner ~= nil then
			owned += 1
		end
	end
	check(owned > 0, "Ownership=NearestPlayer hands nearby props to the closest client")
	check(
		owned <= (Config.Buoyancy.MaxOwnedPerPlayer or 64),
		"per-player ownership respects MaxOwnedPerPlayer (owned " .. tostring(owned) .. ")"
	)
	Config.Buoyancy.Ownership = "Server"
	pumpFrames(3)
	local stillOwned = 0
	for _, model in container:GetChildren() do
		local primary = model.PrimaryPart
		if primary and primary.NetworkOwner ~= nil then
			stillOwned += 1
		end
	end
	check(stillOwned == 0, "switching back to the server releases every owned assembly")
end

-- 18. Clear ring around the player ----------------------------------------------
-- The ring stops new objects from spawning close to a player. A rendered object
-- the player walks up to is in sight, so it must stay in the world.
Config.Streaming.MinPlayerDistance = 200
local ringTarget = buoyantModelNear(rootPart.Position, 6)
if ringTarget then
	rootPart.CFrame = CFrame.new(ringTarget.PrimaryPart.Position.X, 25, ringTarget.PrimaryPart.Position.Z)
	pumpFrames(30)
	check(ringTarget.Parent ~= nil, "a rendered object inside MinPlayerDistance stays in the world (in sight)")
end
Config.Streaming.MinPlayerDistance = 0

-- 19. Ship guard (anti-climb, anti-sink) ---------------------------------------
-- Pure resolver from ShipHandling/ShipGuard: vertical velocity only.
local ShipGuard = assert(load(SOURCES.ShipGuard, "=ShipGuard"))()
local gcfg = ShipGuard.Defaults
local function noContact()
	return false
end
local function inContact()
	return true
end
check(ShipGuard.ResolveVertical(5, 0, nil, noContact, gcfg) == 5, "guard: a free hull keeps its rise")
check(ShipGuard.ResolveVertical(5, 0, nil, inContact, gcfg) == 0, "guard: anti-climb holds a rising hull in contact")
check(ShipGuard.ResolveVertical(-3, 8, 10, inContact, gcfg) == 0, "guard: contact below the goal band stops the sink")
check(ShipGuard.ResolveVertical(-3, 9.5, 10, inContact, gcfg) == -3, "guard: contact inside the goal band keeps normal motion")
check(ShipGuard.ResolveVertical(-10, 5, 10, noContact, gcfg) == 15, "guard: floor lifts a hull 5 below goal by (5 - margin) * gain")
check(ShipGuard.ResolveVertical(-10, 9, 10, noContact, gcfg) == -10, "guard: no floor inside the sink margin")
check(ShipGuard.ResolveVertical(0, -100, 0, noContact, gcfg) == gcfg.MaxRise, "guard: floor lift is capped at MaxRise")
check(ShipGuard.ResolveVertical(4, 0, nil, noContact, gcfg) == 4, "guard: an airborne hull is not touched")
local scans = 0
local function countingContact()
	scans += 1
	return false
end
ShipGuard.ResolveVertical(-1, 9.9, 10, countingContact, gcfg)
check(scans == 0, "guard: contact is not scanned when the answer cannot change")
check(ShipGuard.Gap(5, 10) == 5 and ShipGuard.Gap(5, nil) == 0, "guard gap: below the goal is positive, airborne is zero")
check(ShipGuard.ServoReserve(1, gcfg) == 0, "guard reserve: none within the contact band")
check(math.abs(ShipGuard.ServoReserve(3, gcfg) - 3) < 1e-9, "guard reserve: 1.5 x weight per stud past the band")
check(ShipGuard.ServoReserve(100, gcfg) == gcfg.ReserveMax, "guard reserve: capped at ReserveMax")

-- 20. Swim model (pure) ---------------------------------------------------------
local SwimModel = assert(load(SOURCES.SwimModel, "=SwimModel"))()
local scfg = SwimModel.Config
check(SwimModel.NextState(false, -2, false, scfg) == true, "swim: enters 2 studs below the surface with no floor")
check(SwimModel.NextState(false, -0.5, false, scfg) == false, "swim: does not enter at the surface")
check(SwimModel.NextState(true, 0.5, false, scfg) == true, "swim: stays in at the surface (hysteresis)")
check(SwimModel.NextState(true, 3, false, scfg) == false, "swim: leaves above the exit depth")
check(SwimModel.NextState(false, -5, true, scfg) == false, "swim: ground underfoot means walking, not swimming")
check(SwimModel.SpringSpeed(20, 25, scfg) > 0, "swim spring: lifts a root below the surface")
check(SwimModel.SpringSpeed(30, 25, scfg) < 0, "swim spring: pulls a root above the surface down")
check(SwimModel.SpringSpeed(25, 25, scfg) == 0, "swim spring: zero at the float height")
check(SwimModel.SpringSpeed(-100, 25, scfg) == scfg.MaxSpringSpeed, "swim spring: speed is capped")
local _, idleY = SwimModel.Desired(0, 0, 0, 0, 5, scfg)
check(idleY == 5, "swim desired: an idle swimmer rises to the surface")
local _, diveY = SwimModel.Desired(0, 0, 0, -1, 5, scfg)
check(diveY < 0, "swim desired: the dive key sinks the swimmer against the spring")
local eased = SwimModel.Approach(0, 10, 1 / 60, scfg)
check(eased > 0 and eased < 10, "swim approach: eases toward the desired speed")
local pitch = SwimModel.Tilt(1, 0, 0, 0, 2, 2, scfg)
check(pitch > 0 and pitch <= scfg.MaxTilt, "swim tilt: follows a rising wave front, under the cap")
local cappedPitch = SwimModel.Tilt(100, 0, 0, 0, 2, 2, scfg)
check(math.abs(cappedPitch - scfg.MaxTilt) < 1e-9, "swim tilt: capped at MaxTilt")
check(SwimModel.TintAlpha(-3, scfg) == 0, "swim tint: none above the surface")
check(math.abs(SwimModel.TintAlpha(5, scfg) - 0.5) < 1e-9, "swim tint: half strength at half the full depth")
check(SwimModel.TintAlpha(50, scfg) == 1, "swim tint: full strength when deep")

-- ---------------------------------------------------------------------------
-- FishingRetention: which caught fish to clear
-- ---------------------------------------------------------------------------
local FishingRetention = assert(load(SOURCES.FishingRetention, "=FishingRetention"))()
local rcfg = FishingRetention.Defaults

local function fishEntry(i, age, distance, held)
return { model = "fish" .. i, caughtAt = 1000 + i, age = age, distance = distance, held = held or false }
end

-- under the cap: nothing is cleared, however stale
local list = {}
for i = 1, 10 do list[i] = fishEntry(i, 500, math.huge) end
check(#FishingRetention.SelectClears(list, rcfg) == 0, "retention: under the cap, nothing is cleared")

-- over the cap, all far and old: clear exactly the excess, oldest first
list = {}
for i = 1, 31 do list[i] = fishEntry(i, 500, math.huge) end
local clears = FishingRetention.SelectClears(list, rcfg)
check(#clears == 31 - rcfg.MaxRetained, "retention: clears exactly the excess")
check(clears[1].model == "fish1", "retention: clears the oldest first")
check(clears[#clears].model == "fish" .. (31 - rcfg.MaxRetained), "retention: stops at the cap")

-- near a player: protected even when over the cap
list = {}
for i = 1, 30 do list[i] = fishEntry(i, 500, 10) end
list[31] = fishEntry(31, 0, 10)
check(#FishingRetention.SelectClears(list, rcfg) == 0, "retention: never clears a fish near a player")

-- held: protected even when over the cap and far away
list = {}
for i = 1, 30 do list[i] = fishEntry(i, 500, math.huge, i == 1) end
clears = FishingRetention.SelectClears(list, rcfg)
check(#clears == 0 or clears[1].model ~= "fish1", "retention: never clears a fish being held")

-- the fish just caught: its age keeps it even when everything else is clearable
list = {}
for i = 1, 30 do list[i] = fishEntry(i, 500, math.huge) end
list[31] = fishEntry(31, 0, math.huge)
clears = FishingRetention.SelectClears(list, rcfg)
for _, c in ipairs(clears) do
	check(c.model ~= "fish31", "retention: never clears the fish that was just caught")
end

-- past the hard ceiling the distance protection gives way, or the cap is unbounded
list = {}
for i = 1, rcfg.HardCeiling + 3 do list[i] = fishEntry(i, 500, 10) end
clears = FishingRetention.SelectClears(list, rcfg)
check(#clears == rcfg.HardCeiling + 3 - rcfg.MaxRetained, "retention: past the hard ceiling it clears nearby fish too")

print(("SUMMARY passed=%d failed=%d buoyCalls=%d lookups=%d"):format(TESTS.passed, TESTS.failed, BUOY_CALLS, LOOKUP_CALLS))

-- String globals for the JS runner (avoids iterating Lua tables from JS).
LOGSTRING = ""
for i = 1, LOG.n do
	LOGSTRING = LOGSTRING .. LOG[i] .. "\n"
end
RESULT = tostring(TESTS.passed) .. "/" .. tostring(TESTS.passed + TESTS.failed)
