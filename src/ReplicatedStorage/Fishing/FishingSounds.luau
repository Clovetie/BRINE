-- Sound IDs and playback helpers for the fishing rod and the dive splash.
-- Shared by the server (rod sounds, replicated to everyone) and the client (dive splash,
-- heard by the local player only).

local FishingSounds = {}

-- Fishing rod ----------------------------------------------------------------
FishingSounds.Cast = 86165035080520        -- rod cast
FishingSounds.TookBait = 9114452634        -- fish takes the bait (contact)
FishingSounds.HookClick = 9113463271       -- player clicks to set the hook
FishingSounds.Caught = 9118712043          -- fish caught
FishingSounds.BobberSplash = 9119481281    -- bobber lands / touches water

-- Dive splash (general) ------------------------------------------------------
FishingSounds.DiveLoud = 132575463084009   -- big drops
FishingSounds.DiveQuiet = 92639900093467   -- small and medium drops
FishingSounds.DiveQuietVariant = 100718358915709 -- random alternate for the quiet splash

-- Drops at or above this height (studs) use the loud splash.
FishingSounds.LOUD_DROP = 10
-- Smaller hops than this make no splash at all.
FishingSounds.MIN_DROP = 1.5

function FishingSounds.Id(id: number): string
	return "rbxassetid://" .. tostring(id)
end

-- Creates a sound under `parent` and removes it when it finishes.
function FishingSounds.Play(parent: Instance, id: number, volume: number?, rollOff: number?): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = FishingSounds.Id(id)
	sound.Volume = volume or 1
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = 6
	sound.RollOffMaxDistance = rollOff or 80
	sound.Parent = parent
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	task.delay(30, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
	return sound
end

-- Chooses the dive splash for a drop of `drop` studs. Returns (soundId, volume).
function FishingSounds.DiveFor(drop: number): (number, number)
	if drop >= FishingSounds.LOUD_DROP then
		local volume = math.clamp(0.6 + drop / 40, 0.6, 1)
		return FishingSounds.DiveLoud, volume
	end
	local id = FishingSounds.DiveQuiet
	if math.random() < 0.5 then
		id = FishingSounds.DiveQuietVariant
	end
	local volume = math.clamp(drop / FishingSounds.LOUD_DROP, 0.2, 0.7)
	return id, volume
end

return FishingSounds
