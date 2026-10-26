local RS = game:GetService("ReplicatedStorage")
local WaveFloat = require(RS.FloatingObjectGeneration.WaveFloat)
local out = {}
local ocean = workspace:FindFirstChild("Ocean")
if ocean then
	for _, c in ipairs(ocean:GetChildren()) do
		if c:IsA("BasePart") then
			table.insert(out, c.Name .. " size=" .. string.format("%.0f,%.0f", c.Size.X, c.Size.Z) .. " pos=" .. string.format("%.0f,%.0f,%.0f", c.Position.X, c.Position.Y, c.Position.Z))
		end
	end
end
-- Wave height offset from the 25-stud waterline, sampled on rings out to 1000 studs.
for _, r in ipairs({ 600, 800, 880, 900, 940, 960 }) do
	local worst = 0
	for a = 0, 7 do
		local ang = a * math.pi / 4 + 0.3
		for _, t in ipairs({ 0, 3, 6, 9 }) do
			local p = Vector3.new(math.cos(ang) * r, 25, math.sin(ang) * r)
			local h = WaveFloat.HeightAt(p, nil, nil, nil, t) or 25
			worst = math.max(worst, math.abs(h - 25))
		end
	end
	table.insert(out, string.format("ring r=%d max|dy|=%.2f", r, worst))
end
return table.concat(out, "\n")
