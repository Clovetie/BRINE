local out = {}
local function add(s) table.insert(out, s) end
local ws = workspace
local o = ws:FindFirstChild("Ocean")
add("Ocean: " .. tostring(o ~= nil))
if o then
  local n, meshes, verts = 0, 0, 0
  for _, c in ipairs(o:GetChildren()) do
    n += 1
    add(string.format("  %s %s size=%s pos=%s tr=%s", c.Name, c.ClassName, c:IsA("BasePart") and tostring(c.Size) or "-", c:IsA("BasePart") and tostring(c.Position) or "-", c:IsA("BasePart") and tostring(c.Transparency) or "-"))
  end
  add("  children: " .. n)
end
local L = game:GetService("Lighting")
add(string.format("Lighting brightness=%s ambient=%s outdoor=%s fogStart=%s fogEnd=%s fogColor=%s clock=%s", L.Brightness, tostring(L.Ambient), tostring(L.OutdoorAmbient), L.FogStart, L.FogEnd, tostring(L.FogColor), L.ClockTime))
for _, c in ipairs(L:GetChildren()) do add("  Lighting child: " .. c.ClassName .. " " .. c.Name) end
local kinds = {}
local counts = {MeshPart=0, Part=0, Sound=0, ParticleEmitter=0, Model=0, UnionOperation=0, Terrain=0, Beam=0, Light=0}
local total = 0
for _, d in ipairs(ws:GetDescendants()) do
  total += 1
  if counts[d.ClassName] ~= nil then counts[d.ClassName] += 1 end
  if d:IsA("BasePart") and d.Transparency < 1 then kinds.visible = (kinds.visible or 0) + 1 end
end
add("workspace descendants: " .. total)
for k, v in pairs(counts) do add("  " .. k .. ": " .. v) end
add("visible BaseParts: " .. tostring(kinds.visible))
local t = ws.Terrain
add(string.format("Terrain waterWaveSize=%s waterWaveSpeed=%s waterReflectance=%s waterTransparency=%s", tostring(t.WaterWaveSize), tostring(t.WaterWaveSpeed), tostring(t.WaterReflectance), tostring(t.WaterTransparency)))
local atm = L:FindFirstChildOfClass("Atmosphere")
if atm then add(string.format("Atmosphere density=%s offset=%s color=%s decay=%s glare=%s haze=%s", atm.Density, atm.Offset, tostring(atm.Color), tostring(atm.Decay), atm.Glare, atm.Haze)) end
local cc = L:FindFirstChildOfClass("ColorCorrectionEffect") ; if cc then add("CC present") end
local sky = L:FindFirstChildOfClass("Sky"); add("Sky: " .. tostring(sky ~= nil))
local s = ws:FindFirstChild("GlobalWind"); add("GlobalWind: " .. tostring(s and tostring(s.Value) or "nil"))
return table.concat(out, "\n")
