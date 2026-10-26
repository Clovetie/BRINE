local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local Gerstner = require(game:GetService("ReplicatedStorage"):WaitForChild("Gerstner"))
local WaveFloat = require(game:GetService("ReplicatedStorage").FloatingObjectGeneration.WaveFloat)
local cam = workspace.CurrentCamera
local folder = SoundService:WaitForChild("AmbientSea")
local out = {}
local function vols(label)
	local parts = {}
	for _, name in ipairs({ "CalmBed", "Beach", "Rough", "Wind", "Underwater", "Deep", "Crickets", "NightWind" }) do
		local s = folder[name]
		table.insert(parts, name .. "=" .. string.format("%.2f", s.Volume))
	end
	table.insert(out, label .. " | " .. table.concat(parts, " "))
end
local now = workspace:GetServerTimeNow()
-- Find a calm and a rough point near the origin.
local calmP, roughP, calmS, roughS = nil, nil, 2, -1
for i = 0, 60 do
	local p = Vector3.new(-400 + (i * 37) % 800, 0, -400 + (i * 91) % 800)
	local s = Gerstner.SeaStateAt(Vector3.new(p.X, 25, p.Z), now)
	if s < calmS then calmS, calmP = s, p end
	if s > roughS then roughS, roughP = s, p end
end
table.insert(out, string.format("calm point s=%.2f rough point s=%.2f", calmS, roughS))
local origType, origClock = cam.CameraType, Lighting.ClockTime
cam.CameraType = Enum.CameraType.Scriptable
local function place(p, depth)
	local y = (WaveFloat.HeightAt(Vector3.new(p.X, 25, p.Z), nil, nil, nil, workspace:GetServerTimeNow()) or 25) - depth
	cam.CFrame = CFrame.new(p.X, y, p.Z)
end
Lighting.ClockTime = 12
place(calmP, 1.5); task.wait(3); vols("calm surface, day")
place(roughP, 1.5); task.wait(3); vols("rough surface, day")
place(roughP, 0.5); task.wait(3); vols("rough depth0.5, day")
place(roughP, 3); task.wait(3); vols("rough depth3")
place(roughP, 8); task.wait(3); vols("rough depth8")
place(roughP, 1.5); task.wait(3); vols("rough surface again (no stacking)")
Lighting.ClockTime = 23
place(calmP, 1.5); task.wait(3); vols("calm surface, night")
Lighting.ClockTime = 12
cam.CameraType = origType
Lighting.ClockTime = origClock
local n = 0
for _, c in ipairs(SoundService:GetChildren()) do if c.Name == "AmbientSea" then n = n + 1 end end
table.insert(out, "AmbientSea folders=" .. n)
return table.concat(out, "\n")
