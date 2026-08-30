--!nonstrict

--[[
	IslandGenerationServer
	======================
	Thin server-side orchestrator. All logic lives in IslandGenerator; this script
	just decides WHEN to run and keeps the world tidy.

	Responsibilities:
		* Ensure workspace.Map exists (the folder the ocean depth raycasts and
		  ZoneManager both scan).
		* Run one deterministic scatter pass at startup, cloning premade island
		  templates from ServerStorage.Islands into workspace.Map and tagging them
		  "Island" so ZoneManager indexes them.
		* Nothing here reads client input. There are no RemoteEvents: island
		  placement is fully server-authoritative.

	Reference:
		https://create.roblox.com/docs/reference/engine/classes/ServerStorage
		https://create.roblox.com/docs/reference/engine/classes/Workspace
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- Wait for the modules to exist (Rojo can replicate slightly after scripts run).
local islandFolder = ReplicatedStorage:WaitForChild("IslandGeneration")
local IslandGenerator = require(islandFolder:WaitForChild("IslandGenerator"))

-- workspace.Map is the container ZoneManager and the ocean depth raycasts rely
-- on. Create it now so it is present before the first generation pass.
if not Workspace:FindFirstChild("Map") then
	local mapFolder = Instance.new("Folder")
	mapFolder.Name = "Map"
	mapFolder.Parent = Workspace
end

-- Run the (batched, yielding) scatter pass on its own thread so it never blocks
-- the rest of server startup.
task.spawn(function()
	IslandGenerator.Generate()
end)

-- Note on regenerating / stale state:
-- IslandGenerator.ClearGenerated() removes every island the generator placed and
-- resets the placement octree, leaving any user-dropped anchors in workspace.Map
-- intact. Call it from the command bar or a future admin tool, then
-- IslandGenerator.Generate(), to rebuild deterministically (same world seed +
-- same ServerStorage.Islands content => same world). A player respawn or server
-- restart never leaves stale state because all content is anchored and owned by
-- the server.
