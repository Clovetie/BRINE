local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local lp = Players.LocalPlayer
local char = lp.Character or lp.CharacterAdded:Wait()
local root = char:WaitForChild("HumanoidRootPart")
local cam = workspace.CurrentCamera
local out = {}
local function snap(label)
	table.insert(out, label .. " FogEnd=" .. string.format("%.0f", Lighting.FogEnd) .. " FogCol=" .. tostring(Lighting.FogColor) .. " Reverb=" .. tostring(SoundService.AmbientReverb) .. " tint=" .. tostring(Lighting:FindFirstChild("SwimTint") and Lighting.SwimTint.Enabled))
end
snap("start")
local p = root.Position
local origType = cam.CameraType
cam.CameraType = Enum.CameraType.Scriptable
for _, depth in ipairs({ 0.5, 1.5, 3, 8 }) do
	cam.CFrame = CFrame.new(p.X, 25 - depth, p.Z) * CFrame.Angles(0, 0, 0)
	task.wait(1)
	snap("camdepth" .. depth)
end
cam.CameraType = origType
task.wait(1.5)
snap("restored")
return table.concat(out, "\n")
