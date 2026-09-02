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
		return 25 + math.sin(point.X * 0.01) * 0.9
	end,
}

local SettingsMock = {
	GRID_SETTINGS = { PLANE_OFFSET = Vector3.new(0, 25, 0) },
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

local fogFolder = newInstance("Folder", "FloatingObjectGeneration")
fogFolder.Parent = ReplicatedStorage
local configInst = newInstance("ModuleScript", "FloatingObjectConfig")
configInst.Parent = fogFolder
local generatorInst = newInstance("ModuleScript", "FloatingObjectGenerator")
generatorInst.Parent = fogFolder
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
MODULES[configInst] = { source = "FloatingObjectConfig" }
MODULES[generatorInst] = { source = "FloatingObjectGenerator" }

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
check(BUOY_CALLS > 0 or LOOKUP_CALLS > 0, "wave height lookups occurred")

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

print(("SUMMARY passed=%d failed=%d buoyCalls=%d lookups=%d"):format(TESTS.passed, TESTS.failed, BUOY_CALLS, LOOKUP_CALLS))

-- String globals for the JS runner (avoids iterating Lua tables from JS).
LOGSTRING = ""
for i = 1, LOG.n do
	LOGSTRING = LOGSTRING .. LOG[i] .. "\n"
end
RESULT = tostring(TESTS.passed) .. "/" .. tostring(TESTS.passed + TESTS.failed)
