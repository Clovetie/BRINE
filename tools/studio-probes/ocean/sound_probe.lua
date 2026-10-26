local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local ids = {
	"137826155053556", "78025480791776", "131586509457092", "5033884807", "94473522240855",
	"9120613130", "5799870105", "105990653889537", "179507208", "273398061", "6189441072", "9118747859",
}
local folder = Instance.new("Folder")
folder.Name = "SoundProbe"
folder.Parent = SoundService
local sounds = {}
for _, id in ipairs(ids) do
	local s = Instance.new("Sound")
	s.Name = id
	s.SoundId = "rbxassetid://" .. id
	s.Volume = 0
	s.Looped = true
	s.Parent = folder
	table.insert(sounds, s)
end
pcall(function() ContentProvider:PreloadAsync(sounds) end)
task.wait(3)
local out = {}
for _, s in ipairs(sounds) do
	table.insert(out, s.Name .. " loaded=" .. tostring(s.IsLoaded) .. " len=" .. string.format("%.1f", s.TimeLength))
end
folder:Destroy()
return table.concat(out, "\n")
