--!nonstrict

--[[
	IslandGenerationServer
	======================
	Thin server-side orchestrator. All logic lives in IslandGenerator; this
	script just decides WHEN to run and keeps the world tidy.

	Responsibilities:
		* Ensure workspace.Map exists (the folder the ocean depth raycasts and
		  ZoneManager both scan).
		* Run one deterministic generation pass at startup: user-placed Island
		  anchors are populated first, then procedural islands fill the world.
		* Populate any Island anchor that appears at runtime (e.g. dropped in by
		  a plugin or another script). Generation is one-shot per model.
		* Nothing here reads client input. There are no RemoteEvents: island
		  generation is fully server-authoritative.

	Determinism: every random choice derives from the world seed
	(Settings.Seed, reseeded by Settings when 0) and the per-island index, so
	regenerating with the same seed reproduces the same world.
]]

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Wait for the modules to exist (Rojo can replicate slightly after scripts run).
local islandFolder = ReplicatedStorage:WaitForChild("IslandGeneration")
local IslandGenerator = require(islandFolder:WaitForChild("IslandGenerator"))

-- workspace.Map is the container ZoneManager and the depth raycasts rely on.
local mapFolder = Workspace:FindFirstChild("Map")
if not mapFolder then
	mapFolder = Instance.new("Folder")
	mapFolder.Name = "Map"
	mapFolder.Parent = Workspace
end

-- Run the (batched, yielding) generation pass on its own thread so it never
-- blocks the rest of server startup.
task.spawn(function()
	IslandGenerator.Generate()
end)

-- Populate Island models that are added at runtime. Already-processed anchors
-- and models we generated ourselves are ignored by the generator.
local TAG = "Island"

local function onInstanceAdded(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	if instance:GetAttribute("IslandProcessed") or instance:GetAttribute("GeneratedBy") == "IslandGenerator" then
		return
	end
	-- Defer so a freshly-built anchor model has its Center/Radius parented.
	task.defer(function()
		if instance.Parent == nil then
			return
		end
		if instance:GetAttribute("IslandProcessed") or instance:GetAttribute("GeneratedBy") == "IslandGenerator" then
			return
		end
		-- Runtime anchors receive a high index; the per-index RNG still derives
		-- from the world seed so the result is deterministic for a given world.
		local index = math.max(1, #Workspace.Map:GetChildren() + 1)
		local ok, err = pcall(function()
			IslandGenerator.GenerateForUserIsland(instance, index + 100000)
		end)
		if not ok and not tostring(err):find("aborted") then
			warn("[IslandGenerationServer] runtime island failed: " .. tostring(err))
		end
	end)
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(onInstanceAdded)

-- Also catch anchors parented into Map that arrive without the tag (ZoneManager
-- already scans Map children; we tag them so the signal path covers them too).
mapFolder.ChildAdded:Connect(function(child)
	if child:IsA("Model") and child:FindFirstChild("Center") and not CollectionService:HasTag(child, TAG) then
		CollectionService:AddTag(child, TAG)
	end
end)

-- Note on regenerating / stale state:
-- IslandGenerator.ClearGenerated() removes every created instance and resets
-- internal state (floating objects, octrees, heartbeat), leaving user anchor
-- models intact. Call it from the command bar or a future admin tool, then
-- IslandGenerator.Generate(), to rebuild deterministically. A player respawn or
-- server restart never leaves stale state because all content is anchored and
-- owned by the server; floating objects are tracked and cleaned on clear.
