-- DiveSplash (client): splash sound and spray when the character dives into the sea.
--
-- The drop height is the highest point the character reached in the air since last
-- leaving the water, measured above the sea surface where it goes in. Splash choice
-- (loud for big drops, quieter and varied for small ones) lives in FishingSounds.
-- Nothing plays while the character is seated (on a ship), so this never fires for
-- a passenger. Heard by the local player only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local WaveFloat = require(ReplicatedStorage.FloatingObjectGeneration.WaveFloat)
local FishingSounds = require(ReplicatedStorage.Fishing.FishingSounds)

local player = Players.LocalPlayer

-- Same thresholds as SwimModel (EnterDepth 1.0): well under the surface counts as "in".
local ENTER_DEPTH = 1.0
local EXIT_DEPTH = 0.0

local inWater = false
local peakY: number? = nil

local function surfaceAt(pos: Vector3): number?
	return WaveFloat.HeightAt(pos, nil, nil, "ANALYTIC", workspace:GetServerTimeNow())
end

local function splashAt(pos: Vector3, drop: number)
	local anchor = Instance.new("Part")
	anchor.Name = "DiveSplash"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CFrame = CFrame.new(pos)
	anchor.Parent = workspace

	local id, volume = FishingSounds.DiveFor(drop)
	FishingSounds.Play(anchor, id, volume, 120)

	-- Spray: a burst only, with more spray for bigger drops.
	local spray = Instance.new("ParticleEmitter")
	spray.Enabled = false
	spray.Rate = 0
	spray.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	spray.Lifetime = NumberRange.new(0.6, 1.2)
	spray.Speed = NumberRange.new(8, 8 + math.min(drop, 20) * 0.5)
	spray.SpreadAngle = Vector2.new(80, 80)
	spray.EmissionDirection = Enum.NormalId.Top
	spray.Color = ColorSequence.new(Color3.fromRGB(210, 240, 255))
	spray.Size = NumberSequence.new(0.6, 0.2)
	spray.Transparency = NumberSequence.new(0.2, 1)
	spray.Acceleration = Vector3.new(0, -30, 0)
	spray.Parent = anchor
	spray:Emit(math.floor(20 + math.min(drop, 20)))

	task.delay(4, function()
		anchor:Destroy()
	end)
end

RunService.Heartbeat:Connect(function()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if hum == nil or root == nil or not root:IsA("BasePart") or hum.Health <= 0 then
		inWater = false
		peakY = nil
		return
	end

	local pos = root.Position
	local surface = surfaceAt(pos)
	if surface == nil then
		return
	end
	local depth = pos.Y - surface

	if not inWater then
		if depth >= 0 then
			-- In the air (or on land): remember the highest point reached.
			peakY = math.max(peakY or pos.Y, pos.Y)
		elseif depth < -ENTER_DEPTH then
			-- Went under the surface: this is the dive.
			inWater = true
			local drop = (peakY or pos.Y) - surface
			peakY = nil
			if hum.SeatPart == nil and drop >= FishingSounds.MIN_DROP then
				splashAt(Vector3.new(pos.X, surface, pos.Z), drop)
			end
		end
	elseif depth > EXIT_DEPTH then
		inWater = false
		peakY = pos.Y
	end
end)
