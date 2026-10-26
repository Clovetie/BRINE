local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local lp = Players.LocalPlayer
task.wait(4)
local ocean = workspace:FindFirstChild("Ocean")
local parts = {}
if ocean then
  for _, c in ipairs(ocean:GetChildren()) do
    table.insert(parts, c.Name .. ":" .. c.ClassName)
  end
end
local dts = {}
local t0 = os.clock()
local conn = RunService.Heartbeat:Connect(function(dt) table.insert(dts, dt) end)
while os.clock() - t0 < 6 do task.wait(0.5) end
conn:Disconnect()
table.sort(dts)
local sum = 0
for _, d in ipairs(dts) do sum += d end
local n = #dts
local mean = sum / math.max(n, 1)
local p95 = dts[math.max(1, math.floor(n * 0.95))] or 0
local cam = workspace.CurrentCamera
return string.format("frames=%d meanMs=%.2f p95Ms=%.2f fps=%.1f ocean=%s cam=%s", n, mean*1000, p95*1000, n / 6, table.concat(parts, ","), tostring(cam.CFrame.Position))
