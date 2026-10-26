local o = {}
for _, d in ipairs(workspace:GetDescendants()) do
	if d:IsA("Sound") then
		table.insert(o, d:GetFullName() .. " id=" .. d.SoundId .. " playing=" .. tostring(d.Playing) .. " vol=" .. d.Volume .. " looped=" .. tostring(d.Looped))
	end
end
table.insert(o, "AmbientReverb=" .. tostring(game:GetService("SoundService").AmbientReverb))
return table.concat(o, "\n")
