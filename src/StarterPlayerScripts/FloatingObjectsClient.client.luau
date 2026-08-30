--!nonstrict

--[[
	FloatingObjectsClient
	=====================
	Tiny camera reporter for the floating-object streamer. Every
	ReportInterval seconds it fires the CameraReport RemoteEvent with the
	camera's world position and unit look vector. The server uses these
	reports to decide which unanchored floating objects nobody is LOOKING at
	anymore, and caches those (streaming-style) until a player looks back.

	Deliberately minimal:
		* ~2 tiny packets per second (two Vector3s) per player.
		* No gameplay state is sent; the server fully validates and
		  rate-limits everything it receives.
		* If this script (or the RemoteEvent) is missing, the generator
		  degrades gracefully to distance-only caching.

	Reference:
		https://create.roblox.com/docs/reference/engine/classes/RemoteEvent
		https://create.roblox.com/docs/reference/engine/classes/Camera
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local REPORT_INTERVAL = 0.5

local folder = ReplicatedStorage:WaitForChild("FloatingObjectGeneration")
local cameraReport = folder:WaitForChild("CameraReport")

local camera = workspace.CurrentCamera

local accumulated = 0
RunService.PostSimulation:Connect(function(deltaTime)
	accumulated += deltaTime
	if accumulated < REPORT_INTERVAL then
		return
	end
	accumulated = 0

	if not cameraReport.Parent then
		return -- event was removed; nothing to report to
	end
	if not camera then
		camera = workspace.CurrentCamera
		if not camera then
			return
		end
	end

	local cframe = camera.CFrame
	cameraReport:FireServer(cframe.Position, cframe.LookVector)
end)
