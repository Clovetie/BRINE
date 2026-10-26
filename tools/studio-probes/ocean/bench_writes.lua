local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local G = require(ReplicatedStorage.Gerstner)
local S = require(ReplicatedStorage.Gerstner.Settings)
local em = AssetService:CreateEditableMesh({ FixedSize = true })
local ids = {}
for i = 1, 2000 do ids[i] = em:AddVertex(Vector3.new(i, 0, 0)) end
local cids = {}
for i = 1, 200 do cids[i] = em:AddVertex(Vector3.new(i, 1, 0)) end
local N = 1500
local t = os.clock()
for k = 1, 5 do
  for i = 1, N do em:SetPosition(ids[i], Vector3.new(i, math.sin(k + i), 0)) end
end
local setPos = (os.clock() - t) / (5 * N)
t = os.clock()
for k = 1, 5 do
  for i = 1, N do em:SetPosition(ids[i], Vector3.new(i, math.sin(k + i), 0)) end
end
setPos = (os.clock() - t) / (5 * N)
local uvId = em:AddUV(Vector2.new(0, 0))
t = os.clock()
for k = 1, 5 do for i = 1, N do em:SetUV(uvId, Vector2.new(k, i)) end end
local setUV = (os.clock() - t) / (5 * N)
local col = em:AddColor(Color3.new(0, 0, 0), 1)
t = os.clock()
for k = 1, 5 do for i = 1, N do em:SetColor(col, Color3.new(k / 5, i / N, 0.5)) end end
local setCol = (os.clock() - t) / (5 * N)
-- wave kernel: ComputeTransform for one point
local waves = S.Waves
t = os.clock()
for i = 1, 5000 do G.ComputeTransform(waves, Vector3.new(i, 25, i * 0.5), 1.0, 1, 1, 1) end
local kernel = (os.clock() - t) / 5000
t = os.clock()
for i = 1, 5000 do G.SeaStateAt(Vector3.new(i, 25, i * 0.5), 1.0) end
local sea = (os.clock() - t) / 5000
return string.format("SetPosition=%.2fus SetUV=%.2fus SetColor=%.2fus ComputeTransform=%.2fus SeaStateAt=%.2fus", setPos*1e6, setUV*1e6, setCol*1e6, kernel*1e6, sea*1e6)
