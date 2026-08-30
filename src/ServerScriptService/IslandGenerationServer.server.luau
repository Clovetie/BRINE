--!nonstrict

--[[
	IslandGenerationServer
	======================
	Thin server-side orchestrator. All logic lives in IslandGenerator; this script
	just decides WHEN to run and keeps the world tidy.

	Responsibilities:
		* Ensure workspace.Map exists (the folder the ocean depth raycasts and
		  ZoneManager both scan).
		* Start the deterministic streaming pass at startup. As players move, the
		  generator caches island records around them, clones only nearby records,
		  tweens them upward, and moves risen islands into workspace.Map tagged
		  "Island" so ZoneManager indexes their final positions.
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

-- Start the (batched, yielding) streaming loop on its own thread so it never
-- blocks the rest of server startup.
task.spawn(function()
	IslandGenerator.Generate()
end)

-- Note on regenerating / stale state:
-- IslandGenerator.ClearGenerated() removes every generated island model and
-- resets the streaming/cache/octree state, leaving any user-dropped anchors in
-- workspace.Map intact. Call it from the command bar or a future admin tool,
-- then IslandGenerator.Generate(), to restart deterministic streaming. A player
-- respawn never leaves stale state because generated island content is anchored
-- and owned by the server.
