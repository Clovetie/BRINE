local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ps = Players.LocalPlayer:WaitForChild("PlayerScripts")
local MODE = "__MODE__"
if MODE == "off" then
  for _, c in ipairs(ps:GetDescendants()) do
    if c:IsA("Actor") then c:Destroy() end
  end
  task.wait(1)
end
task.wait(1)
local seconds = {}
local all = {}
local window = {}
local t0 = os.clock()
local conn = RunService.Heartbeat:Connect(function(dt)
  table.insert(all, dt)
  table.insert(window, dt)
end)
for s = 1, 12 do
  local ws = os.clock()
  task.wait(1)
  local sum, n = 0, 0
  for _, d in ipairs(window) do sum += d; n += 1 end
  table.clear(window)
  if n > 0 then table.insert(seconds, n / sum) end
end
conn:Disconnect()
table.sort(seconds)
table.sort(all)
local sumAll = 0
for _, d in ipairs(all) do sumAll += d end
local medFps = seconds[math.ceil(#seconds / 2)]
local p95 = all[math.max(1, math.floor(#all * 0.95))]
return string.format("MODE=%s medianFps=%.1f meanMs=%.2f p95Ms=%.2f frames=%d", MODE, medFps, sumAll / #all * 1000, p95 * 1000, #all)
