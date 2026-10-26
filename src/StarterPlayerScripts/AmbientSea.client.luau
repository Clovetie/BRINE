--!strict
-- Ambient sea sound, client only.
--
-- Every track plays on a loop (or on a random timer for one-shots) and only its Volume changes.
-- The mix is set from what the camera sees and hears each frame: sea state (calm or rough),
-- depth below the surface (surface or underwater), and the clock (day or night). Because the
-- volumes follow targets rather than start and stop triggers, repeated dives do not stack sounds.
--
-- Config lives in CONFIG below. Track IDs are the user-supplied assets (see ocean/SOUND_PROMPT.md).

local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Gerstner = require(ReplicatedStorage:WaitForChild("Gerstner"))
local WaveFloat = require(ReplicatedStorage.FloatingObjectGeneration.WaveFloat)

local CONFIG = {
	Track = {
		CalmBed = 78025480791776, -- Soothing ocean waves (loop)
		Beach = 137826155053556, -- Ocean waves on beach (loop, low layer)
		Rough = 9120613130, -- Rough waves (loop, 11 s)
		Underwater = 5033884807, -- Underwater loop
		Deep = 94473522240855, -- Deep underwater loop
		Wind = 5799870105, -- Ambient wind (loop)
		Gust = 9118747859, -- Wind howl (one-shot)
		Birds = 105990653889537, -- Bird chirping (one-shot)
		Crickets = 179507208, -- Night ambience with crickets (loop)
		NightWind = 6189441072, -- Wind ambience night (loop)
	},
	-- Full volume for each role. The mix scales these.
	Volume = {
		CalmBed = 0.5,
		Beach = 0.2,
		Rough = 0.6,
		Wind = 0.35,
		Gust = 0.5,
		Birds = 0.25,
		Crickets = 0.35,
		NightWind = 0.3,
		Underwater = 0.7,
		Deep = 0.8,
	},
	FadeRate = 1.5, -- volume units per second, how fast volumes follow their targets
	-- Depth in studs below the surface.
	UnderwaterFullDepth = 3,
	DeepStart = 3,
	DeepFullDepth = 11,
	-- Random one-shot timers, in seconds.
	GustInterval = { 15, 40 },
	BirdInterval = { 8, 25 },
	-- Clock hours (Lighting.ClockTime). Birds only in daytime; crickets and night wind at night.
	DayStart = 6,
	DayEnd = 18,
	NightStart = 19,
	NightEnd = 5,
	-- Gusts only when the sea is rough enough (roughness 0..1).
	GustMinRoughness = 0.3,
}

local folder = Instance.new("Folder")
folder.Name = "AmbientSea"
folder.Parent = SoundService

type Track = { sound: Sound, target: number, full: number }
local tracks: { [string]: Track } = {}

local function makeSound(name: string, id: number, looped: boolean)
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = "rbxassetid://" .. tostring(id)
	s.Looped = looped
	s.Volume = 0
	s.Parent = folder
	return s
end

local function addLoop(name: string, id: number, full: number)
	local s = makeSound(name, id, true)
	s:Play()
	tracks[name] = { sound = s, target = 0, full = full }
end

addLoop("CalmBed", CONFIG.Track.CalmBed, CONFIG.Volume.CalmBed)
addLoop("Beach", CONFIG.Track.Beach, CONFIG.Volume.Beach)
addLoop("Rough", CONFIG.Track.Rough, CONFIG.Volume.Rough)
addLoop("Underwater", CONFIG.Track.Underwater, CONFIG.Volume.Underwater)
addLoop("Deep", CONFIG.Track.Deep, CONFIG.Volume.Deep)
addLoop("Wind", CONFIG.Track.Wind, CONFIG.Volume.Wind)
addLoop("Crickets", CONFIG.Track.Crickets, CONFIG.Volume.Crickets)
addLoop("NightWind", CONFIG.Track.NightWind, CONFIG.Volume.NightWind)

local gust = makeSound("Gust", CONFIG.Track.Gust, false)
gust.Volume = CONFIG.Volume.Gust
local birds = makeSound("Birds", CONFIG.Track.Birds, false)
birds.Volume = CONFIG.Volume.Birds

-- Mix state, updated each frame from the camera.
local roughness = 0 -- 0 calm, 1 rough
local underwater = 0 -- 0 surface, 1 at full depth
local deepness = 0 -- 0 to 1 within the deep band
local night = 0 -- 0 day, 1 night

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

local function inHours(hour: number, startHour: number, endHour: number): boolean
	if startHour <= endHour then
		return hour >= startHour and hour < endHour
	end
	return hour >= startHour or hour < endHour
end

-- Mix targets from the current state. Each track's target is a fraction of its full volume.
local function computeTargets()
	local surface = 1 - underwater
	local calm = 1 - roughness
	local rough = roughness
	local dayHour = Lighting.ClockTime
	local isDay = inHours(dayHour, CONFIG.DayStart, CONFIG.DayEnd)
	local isNight = inHours(dayHour, CONFIG.NightStart, CONFIG.NightEnd)
	night = night + ((isNight and 1 or 0) - night) * 0.05

	tracks.CalmBed.target = surface * calm
	tracks.Beach.target = surface * 0.7
	tracks.Rough.target = surface * rough
	tracks.Wind.target = surface * (0.25 + 0.75 * roughness)
	tracks.Underwater.target = underwater * (1 - deepness)
	tracks.Deep.target = underwater * deepness
	tracks.Crickets.target = night * surface
	tracks.NightWind.target = night * surface
	-- Birds and gusts are one-shot timers, so their volumes are set directly in the mix below.
	birds.Volume = if isDay and surface > 0.5 then CONFIG.Volume.Birds else 0
end

local function mixVolumes(dt: number)
	local step = CONFIG.FadeRate * dt
	for _, track in tracks do
		local v = track.sound.Volume
		local goal = track.target * track.full
		local nv = v + math.clamp(goal - v, -step, step)
		if nv ~= v then
			track.sound.Volume = nv
		end
	end
end

local function randomBetween(range: { number }): number
	return range[1] + math.random() * (range[2] - range[1])
end

-- One-shot timers.
task.spawn(function()
	while true do
		task.wait(randomBetween(CONFIG.GustInterval))
		if roughness >= CONFIG.GustMinRoughness and underwater < 0.1 and not gust.IsPlaying then
			gust:Play()
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(randomBetween(CONFIG.BirdInterval))
		if birds.Volume > 0 and not birds.IsPlaying then
			birds:Play()
		end
	end
end)

-- Per-frame: read the camera, update the mix, and set volumes.
RunService.Heartbeat:Connect(function(dt)
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local now = workspace:GetServerTimeNow()
	local camPos = camera.CFrame.Position

	local seaState = Gerstner.SeaStateAt(camPos, now)
	roughness = clamp01((seaState - Gerstner.SEA_STATE_CALM) / (1 - Gerstner.SEA_STATE_CALM))

	local surfaceY = WaveFloat.HeightAt(camPos, nil, nil, nil, now)
	local depth = if surfaceY ~= nil then surfaceY - camPos.Y else -1
	underwater = clamp01(depth / CONFIG.UnderwaterFullDepth)
	deepness = clamp01((depth - CONFIG.DeepStart) / (CONFIG.DeepFullDepth - CONFIG.DeepStart))

	computeTargets()
	mixVolumes(dt)
end)
