--!nonstrict
--!optimize 2

-- Swimming (client). Works for R6 and R15 characters: it only uses the Humanoid and
-- HumanoidRootPart, which both rigs have.
--
-- When the character sinks below the wave surface with nothing solid underneath, it
-- switches to swimming (SwimModel.NextState). Swimming:
--   * The root is pulled toward the same analytic wave surface the floating props and
--     ships ride (WaveFloat.HeightAt), so it follows the crests and troughs.
--   * The body tilts with the local wave slope, capped (SwimModel.Tilt).
--   * Gravity is cancelled with a VectorForce, so the spring alone sets the height.
--   * WASD swims in the camera's direction, including up and down when the camera looks
--     that way. Space rises, and Left Ctrl or Left Shift dives. Releasing the dive keys
--     lets the swimmer rise back to the surface. There is no floor in the void.
--   * The view tints blue as the camera goes under the surface, and deepens with depth.
--
-- The character's physics belongs to the local player, so these forces replicate to the
-- server like any other movement. Sitting in a seat (a ship) or dying ends a swim.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")

local WaveFloat = require(ReplicatedStorage.FloatingObjectGeneration.WaveFloat)
local ZoneManager = require(ReplicatedStorage.Gerstner.Serial.ZoneManager)
local SwimModel = require(ReplicatedStorage.Swimming.SwimModel)
local cfg = SwimModel.Config

local localPlayer = Players.LocalPlayer

-- Body footprint used to sample the wave slope. The root part is 2 wide and 1 deep.
local HALF_LENGTH = 0.5
local HALF_WIDTH = 1.0
-- Ray length from the root to find a floor under the swimmer (beach, pier, deck).
local FLOOR_PROBE = 4
-- Zone refresh interval (islands and whirlpools change the wave field).
local ZONE_REFRESH = 3

-- Underwater view ----------------------------------------------------------------

local tint = Instance.new("ColorCorrectionEffect")
tint.Name = "SwimTint"
tint.Enabled = false
tint.Parent = Lighting

local overlayGui = Instance.new("ScreenGui")
overlayGui.Name = "SwimOverlay"
overlayGui.IgnoreGuiInset = true
overlayGui.ResetOnSpawn = false
overlayGui.DisplayOrder = -10

local overlay = Instance.new("Frame")
overlay.Name = "Blue"
overlay.Size = UDim2.fromScale(1, 1)
overlay.BackgroundColor3 = Color3.fromRGB(40, 110, 220)
overlay.BackgroundTransparency = 1
overlay.BorderSizePixel = 0
overlay.Parent = overlayGui

task.spawn(function()
	overlayGui.Parent = localPlayer:WaitForChild("PlayerGui")
end)

-- Murk settings: how deep the water closes in, and the view distance and colour at full depth.
local MURK_DEPTH = 3
local MURK_FOG_END = 120
local MURK_FOG_COLOR = Color3.fromRGB(18, 80, 96)
local fogEndDefault = Lighting.FogEnd
local fogColorDefault = Lighting.FogColor
local lastMurk = 0

-- Zone state -----------------------------------------------------------------------

local zone = {
	SpeedMultiplier = 1,
	PhaseMultiplier = 1,
	AmplitudeMultiplier = 1,
	CURRENT_ZONE = nil,
}
local zoneAccumulated = ZONE_REFRESH

local function refreshZone(position: Vector3)
	local current = ZoneManager:GetZoneParameters(position)
	zone.CURRENT_ZONE = current
	if current and current.Type ~= "Whirlpool" then
		if current.Link then
			zone.PhaseMultiplier, zone.SpeedMultiplier, zone.AmplitudeMultiplier =
				ZoneManager:GetZoneMultipliers(position, current.Link.Position, current)
		elseif current.Island then
			zone.PhaseMultiplier, zone.SpeedMultiplier, zone.AmplitudeMultiplier =
				ZoneManager:GetIslandMultipliers(position, current.Island.Center.Position, current.Radius / 2)
		end
	end
end

-- Character state ------------------------------------------------------------------

local character = nil
local humanoid = nil
local root = nil
local lift = nil
local align = nil
local swimming = false

local function setSwimming(on: boolean)
	if on == swimming or humanoid == nil then
		return
	end
	swimming = on
	if on then
		humanoid.AutoRotate = false
		humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
		lift.Enabled = true
		align.Enabled = true
	else
		lift.Enabled = false
		align.Enabled = false
		humanoid.AutoRotate = true
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	end
end

local function build(char: Model)
	character = char
	humanoid = char:WaitForChild("Humanoid")
	root = char:WaitForChild("HumanoidRootPart")

	local attachment = Instance.new("Attachment")
	attachment.Name = "SwimAttachment"
	attachment.Parent = root

	lift = Instance.new("VectorForce")
	lift.Name = "SwimLift"
	lift.Attachment0 = attachment
	lift.RelativeTo = Enum.ActuatorRelativeTo.World
	lift.ApplyAtCenterOfMass = true
	lift.Force = Vector3.zero
	lift.Enabled = false
	lift.Parent = root

	align = Instance.new("AlignOrientation")
	align.Name = "SwimOrientation"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.MaxAngularVelocity = 8
	align.Responsiveness = 18
	align.RigidityEnabled = false
	align.MaxTorque = 0
	align.Enabled = false
	align.Parent = root

	swimming = false
	zoneAccumulated = ZONE_REFRESH
end

local function clearCharacter()
	swimming = false
	character = nil
	humanoid = nil
	root = nil
	lift = nil
	align = nil
end

local function onCharacterAdded(char: Model)
	clearCharacter()
	build(char)
end

localPlayer.CharacterAdded:Connect(onCharacterAdded)
localPlayer.CharacterRemoving:Connect(clearCharacter)
if localPlayer.Character then
	onCharacterAdded(localPlayer.Character)
end

-- Helpers ----------------------------------------------------------------------------

local function surfaceAt(point: Vector3, now: number): number
	return WaveFloat.HeightAt(point, zone, nil, nil, now)
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true -- the sea mesh is CanCollide=false, so it is not floor

local function inputDirection(): (Vector3, number)
	local camera = workspace.CurrentCamera
	local cf = camera.CFrame
	local forward = (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0)
		- (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0)
	local strafe = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0)
		- (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
	local vertical = (UserInputService:IsKeyDown(Enum.KeyCode.Space) and 1 or 0)
		- (
			(UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.LeftShift))
				and 1
			or 0
		)
	local dir = cf.LookVector * forward + cf.RightVector * strafe
	if dir.Magnitude > 1 then
		dir = dir.Unit
	end
	return dir, vertical
end

-- Per-frame ----------------------------------------------------------------------------

RunService.PreSimulation:Connect(function(dt)
	if humanoid == nil or root == nil or character == nil or character.Parent == nil then
		return
	end

	local camera = workspace.CurrentCamera
	local now = workspace:GetServerTimeNow()

	zoneAccumulated += dt
	if zoneAccumulated >= ZONE_REFRESH then
		zoneAccumulated = 0
		refreshZone(root.Position)
	end

	-- Wave samples under the four corners of the body, in the same frame as the
	-- prop solve: front is along the look vector, right along the right vector.
	local cf = root.CFrame
	local pos = root.Position
	local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
	if look.Magnitude < 1e-3 then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end
	if right.Magnitude < 1e-3 then
		right = Vector3.new(1, 0, 0)
	else
		right = right.Unit
	end

	local front = surfaceAt(pos + look * HALF_LENGTH, now)
	local back = surfaceAt(pos - look * HALF_LENGTH, now)
	local rightH = surfaceAt(pos + right * HALF_WIDTH, now)
	local leftH = surfaceAt(pos - right * HALF_WIDTH, now)
	local surface = (front + back + rightH + leftH) / 4

	local depth = SwimModel.Depth(pos.Y, surface)

	-- Is there solid ground under the swimmer, above the water?
	rayParams.FilterDescendantsInstances = { character }
	local hit = workspace:Raycast(pos, Vector3.new(0, -FLOOR_PROBE, 0), rayParams)
	local ground = hit ~= nil and hit.Position.Y > surface - 1

	local wantSwim = SwimModel.NextState(swimming, depth, ground, cfg)
	if humanoid.Health <= 0 or humanoid.SeatPart ~= nil then
		wantSwim = false
	end
	setSwimming(wantSwim)

	if swimming then
		local dir, vertical = inputDirection()
		local springY = SwimModel.SpringSpeed(pos.Y, surface, cfg)
		local dx, dy, dz = SwimModel.Desired(dir.X, dir.Y, dir.Z, vertical, springY, cfg)

		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(
			SwimModel.Approach(v.X, dx, dt, cfg),
			SwimModel.Approach(v.Y, dy, dt, cfg),
			SwimModel.Approach(v.Z, dz, dt, cfg)
		)

		-- Cancel gravity; the spring sets the height.
		lift.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity, 0)

		-- Body follows the wave slope, with yaw turned toward the swim direction.
		local pitch, roll = SwimModel.Tilt(
			front,
			back,
			rightH,
			leftH,
			HALF_LENGTH * 2,
			HALF_WIDTH * 2,
			cfg
		)
		local yaw
		if math.sqrt(dx * dx + dz * dz) > 1 then
			yaw = math.atan2(-dx, -dz)
		else
			yaw = math.atan2(-look.X, -look.Z)
		end
		align.MaxTorque = math.max(root.AssemblyMass * 4000, 1)
		align.CFrame = CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, roll)
	end

	-- Underwater view: how far the camera is below the surface at its own position.
	local camPos = camera.CFrame.Position
	local camDepth = surfaceAt(camPos, now) - camPos.Y
	local alpha = SwimModel.TintAlpha(camDepth, cfg)
	tint.Enabled = alpha > 0.001
	tint.TintColor = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(90, 160, 255), alpha)
	tint.Brightness = -0.08 * alpha
	tint.Saturation = -0.15 * alpha
	overlay.BackgroundTransparency = 1 - 0.35 * alpha

	-- Murk: the classic fog closes in over the first MURK_DEPTH studs below the surface,
	-- and the sound takes on underwater reverb. Both are local to this client.
	local murk = math.clamp(camDepth / MURK_DEPTH, 0, 1)
	if murk ~= lastMurk then
		lastMurk = murk
		local closing = (1 - murk) ^ 3
		Lighting.FogEnd = MURK_FOG_END + (fogEndDefault - MURK_FOG_END) * closing
		Lighting.FogColor = fogColorDefault:Lerp(MURK_FOG_COLOR, murk)
		local reverb = if murk > 0.5 then Enum.ReverbType.UnderWater else Enum.ReverbType.NoReverb
		if SoundService.AmbientReverb ~= reverb then
			SoundService.AmbientReverb = reverb
		end
	end
end)
