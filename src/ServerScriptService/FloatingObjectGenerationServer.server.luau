--!nonstrict

--[[
	FloatingObjectGenerationServer
	===============================
	Thin server-side orchestrator, mirroring IslandGenerationServer. All
	logic lives in FloatingObjectGenerator; this script decides WHEN to run,
	owns the CameraReport RemoteEvent, and keeps per-player state tidy.

	Responsibilities:
		* Start the deterministic floating-object streaming pass at startup.
		* Receive lightweight camera reports (position + look vector, ~2 Hz)
		  from FloatingObjectsClient and forward them, validated and
		  rate-limited, into FloatingObjectGenerator.SetCameraState. The
		  generator uses them for the "no longer looking at it" cache logic;
		  nothing gameplay-critical ever flows client -> server.
		* Drop camera state on PlayerRemoving.

	Reference:
		https://create.roblox.com/docs/reference/engine/classes/RemoteEvent
		https://create.roblox.com/docs/reference/engine/classes/Players
		https://create.roblox.com/docs/reference/engine/classes/ServerScriptService
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Wait for the module folder (Rojo can replicate slightly after scripts run).
local folder = ReplicatedStorage:WaitForChild("FloatingObjectGeneration")
local FloatingObjectGenerator = require(folder:WaitForChild("FloatingObjectGenerator"))

-- The CameraReport RemoteEvent ships with the folder via Rojo
-- (CameraReport.model.json). Create a fallback at runtime if it is missing so
-- the system still works when the place was assembled by hand.
local cameraReport = folder:FindFirstChild("CameraReport")
if not (cameraReport and cameraReport:IsA("RemoteEvent")) then
	cameraReport = Instance.new("RemoteEvent")
	cameraReport.Name = "CameraReport"
	cameraReport.Parent = folder
end

-- Per-player rate limit. Clients send ~2 reports/second; anything faster is
-- either a glitch or an exploit attempt and is dropped.
local lastReportAt = {}
local minInterval = Config.Streaming.CameraMinReportInterval or 0.1

cameraReport.OnServerEvent:Connect(function(player, cameraPos, cameraLook)
	local now = os.clock()
	local last = lastReportAt[player]
	if last and now - last < minInterval then
		return
	end
	lastReportAt[player] = now

	FloatingObjectGenerator.SetCameraState(player, cameraPos, cameraLook)
end)

Players.PlayerRemoving:Connect(function(player)
	lastReportAt[player] = nil
	FloatingObjectGenerator.RemovePlayer(player)
end)

-- Start the (batched, yielding) streaming loop on its own thread so it never
-- blocks the rest of server startup.
task.spawn(function()
	FloatingObjectGenerator.Generate()
end)

-- Note on regenerating / stale state:
-- FloatingObjectGenerator.ClearGenerated() destroys every generated floating
-- object, resets the streaming/cache/octree state (hand-placed tagged objects
-- are preserved), and can be followed by Generate() to restart streaming.
