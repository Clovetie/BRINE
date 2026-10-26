local Players = game:GetService("Players")
local ps = Players.LocalPlayer:WaitForChild("PlayerScripts")
local n = 0
local function killActors(root)
  for _, c in ipairs(root:GetDescendants()) do
    if c:IsA("Actor") then c:Destroy(); n += 1 end
  end
end
local og = ps:FindFirstChild("OceanParallel")
if og then killActors(og) end
local sg = ps:FindFirstChild("OceanParallel", true)
task.wait(1.5)
local RunService = game:GetService("RunService")
local dts = {}
local t0 = os.clock()
local conn = RunService.Heartbeat:Connect(function(dt) table.insert(dts, dt) end)
while os.clock() - t0 < 6 do task.wait(0.5) end
conn:Disconnect()
table.sort(dts)
local sum = 0
for _, d in ipairs(dts) do sum += d end
local k = #dts
return string.format("actorsDestroyed=%d og=%s frames=%d meanMs=%.2f p95Ms=%.2f fps=%.1f", n, tostring(og ~= nil), k, sum/math.max(k,1)*1000, (dts[math.max(1, math.floor(k*0.95))] or 0)*1000, k/6)
