--!nonstrict
--!optimize 2

-- ROADMAP 4.3: island sound and tween helpers (rise/sink animation and cues).
-- Tween state is passed in by the caller (tweenStore), so this module holds none.

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local Config = require(script.Parent.IslandConfig)

local ASSET_ID_PREFIX = "rbxassetid://"

local Presentation = {}

-- Sound / tween helpers --------------------------------------------------------

local function normalizeSoundId(soundId): string
	local soundIdType = type(soundId)
	if soundIdType == "number" then
		return ASSET_ID_PREFIX .. tostring(soundId)
	elseif soundIdType == "string" then
		if soundId == "" then
			return ""
		end
		if tonumber(soundId) then
			return ASSET_ID_PREFIX .. soundId
		end
		return soundId
	end
	return ""
end

local function playConfiguredSound(model: Model, soundConfig, soundName: string)
	local soundId = normalizeSoundId(soundConfig.SoundId)
	if soundId == "" then
		return
	end

	local parent: Instance = model.PrimaryPart or model:FindFirstChild(Config.CenterPartName) or model
	local sound = Instance.new("Sound")
	sound.Name = soundName
	sound.SoundId = soundId
	sound.Volume = soundConfig.SoundVolume or 0.8
	sound.RollOffMaxDistance = soundConfig.SoundRollOffMaxDistance or 500
	sound.Parent = parent
	sound:Play()

	local cleanupDelay = math.max(soundConfig.SoundCleanupDelay or 10, (soundConfig.TweenTime or 4) + 10)
	Debris:AddItem(sound, cleanupDelay)
end

local function makeTweenInfo(tweenConfig, defaultStyle, defaultDirection): TweenInfo
	return TweenInfo.new(
		math.max(0.05, tweenConfig.TweenTime or 4),
		tweenConfig.EasingStyle or defaultStyle,
		tweenConfig.EasingDirection or defaultDirection
	)
end

local function cleanupPivotTween(tweenStore, record)
	local active = tweenStore[record]
	if not active then
		return
	end

	tweenStore[record] = nil
	if active.completedConnection then
		active.completedConnection:Disconnect()
	end
	if active.changedConnection then
		active.changedConnection:Disconnect()
	end
	if active.tween then
		active.tween:Cancel()
	end
	if active.pivotValue then
		active.pivotValue:Destroy()
	end
end

local function tweenModelPivot(record, tweenStore, tweenInfo: TweenInfo, goalPivot: CFrame, onCompleted)
	local model = record.model
	if not model or not model.Parent then
		return nil
	end

	cleanupPivotTween(tweenStore, record)

	local pivotValue = Instance.new("CFrameValue")
	pivotValue.Value = model:GetPivot()

	local changedConnection = pivotValue:GetPropertyChangedSignal("Value"):Connect(function()
		if model.Parent then
			model:PivotTo(pivotValue.Value)
		end
	end)

	local tween = TweenService:Create(pivotValue, tweenInfo, {
		Value = goalPivot,
	})
	local active = {
		tween = tween,
		pivotValue = pivotValue,
		changedConnection = changedConnection,
		completedConnection = nil,
	}
	tweenStore[record] = active

	local completedConnection
	completedConnection = tween.Completed:Connect(function(playbackState)
		if completedConnection then
			completedConnection:Disconnect()
		end
		if changedConnection then
			changedConnection:Disconnect()
		end
		if pivotValue then
			pivotValue:Destroy()
		end
		tweenStore[record] = nil

		if playbackState == Enum.PlaybackState.Completed then
			onCompleted()
		end
	end)
	active.completedConnection = completedConnection

	tween:Play()
	return tween
end

Presentation.playConfiguredSound = playConfiguredSound
Presentation.makeTweenInfo = makeTweenInfo
Presentation.cleanupPivotTween = cleanupPivotTween
Presentation.tweenModelPivot = tweenModelPivot

return Presentation
