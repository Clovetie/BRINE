-- Template: __MODE__ is "find" or "set"; for "set", __X__ __Z__ __DEPTH__ __CLOCK__ are filled in.
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local RS = game:GetService("ReplicatedStorage")
local Gerstner = require(RS:WaitForChild("Gerstner"))
local WaveFloat = require(RS.FloatingObjectGeneration.WaveFloat)
local cam = workspace.CurrentCamera
local now = workspace:GetServerTimeNow()
if "__MODE__" == "find" then
	local calmP, roughP, calmS, roughS = nil, nil, 2, -1
	for i = 0, 60 do
		local x, z = -400 + (i * 37) % 800, -400 + (i * 91) % 800
		local s = Gerstner.SeaStateAt(Vector3.new(x, 25, z), now)
		if s < calmS then calmS, calmP = s, { x, z } end
		if s > roughS then roughS, roughP = s, { x, z } end
	end
	return string.format("calm %.2f %.1f %.1f | rough %.2f %.1f %.1f", calmS, calmP[1], calmP[2], roughS, roughP[1], roughP[2])
end
cam.CameraType = Enum.CameraType.Scriptable
local x, z = __X__, __Z__
Lighting.ClockTime = __CLOCK__
-- Keep the camera at the requested depth relative to the moving surface for 4 s.
for i = 1, 40 do
	local t = workspace:GetServerTimeNow()
	local y = (WaveFloat.HeightAt(Vector3.new(x, 25, z), nil, nil, nil, t) or 25) - __DEPTH__
	cam.CFrame = CFrame.new(x, y, z)
	task.wait(0.1)
end
local f = SoundService:FindFirstChild("AmbientSea")
local parts = {}
for _, name in ipairs({ "CalmBed", "Beach", "Rough", "Wind", "Underwater", "Deep", "Crickets", "NightWind" }) do
	table.insert(parts, name .. "=" .. string.format("%.2f", f[name].Volume))
end
local birds = f.Birds.Volume
return "__LABEL__ | " .. table.concat(parts, " ") .. " Birds=" .. string.format("%.2f", birds)
