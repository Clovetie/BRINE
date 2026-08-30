--!nonstrict
-- Hand-Holding Client
-- The client only:
--   1. Toggles hand-holding on/off with L (L is not a hold key).
--   2. Picks an intended target using facing direction + distance.
--   3. Tells the server ("PressL", target) / ("ReleaseL").
--
-- The server validates everything else and owns the hand-holding state.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local handHoldingFolder = ReplicatedStorage:WaitForChild("HandHolding")
local remoteEvent = handHoldingFolder:WaitForChild("HandHoldingEvent") :: RemoteEvent
local config = require(handHoldingFolder:WaitForChild("HandHoldingConfig"))

local MAX_DISTANCE = config.MAX_DISTANCE
local MAX_LOOK_ANGLE_DEGREES = config.MAX_LOOK_ANGLE_DEGREES

local localPlayer = Players.LocalPlayer

-- This is a toggle state, not the physical keyboard state. The server will
-- keep the joint active until L is pressed again or validation fails.
local holdingL = false

local function getBestTarget()
	local character = localPlayer.Character
	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end

	local lookVector = root.CFrame.LookVector
	local bestPlayer
	local bestScore = -math.huge

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= localPlayer then
			local otherCharacter = otherPlayer.Character
			if otherCharacter then
				local otherRoot = otherCharacter:FindFirstChild("HumanoidRootPart")
				if otherRoot then
					local delta = otherRoot.Position - root.Position
					local dist = delta.Magnitude

					if dist > 0 and dist <= MAX_DISTANCE then
						local direction = delta.Unit
						local cosAngle = lookVector:Dot(direction)
						local angleDeg = math.deg(math.acos(math.clamp(cosAngle, -1, 1)))

						if angleDeg <= MAX_LOOK_ANGLE_DEGREES then
							-- Prefer closer players and players closer to the
							-- center of the facing cone.
							local score = (1 - angleDeg / MAX_LOOK_ANGLE_DEGREES) * 2
								+ (1 - dist / MAX_DISTANCE)
							if score > bestScore then
								bestScore = score
								bestPlayer = otherPlayer
							end
						end
					end
				end
			end
		end
	end

	return bestPlayer
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or input.KeyCode ~= Enum.KeyCode.L then
		return
	end

	-- Toggle: one press starts/offers or accepts; the next press releases.
	-- InputEnded is intentionally not used, so the player does not have to
	-- physically hold the key down.
	holdingL = not holdingL
	if holdingL then
		remoteEvent:FireServer("PressL", getBestTarget())
	else
		remoteEvent:FireServer("ReleaseL")
	end
end)

-- If the character disappears while toggled on, clear the local state. The
-- server also cleans up the authoritative connection on CharacterRemoving.
localPlayer.CharacterRemoving:Connect(function()
	if holdingL then
		holdingL = false
		remoteEvent:FireServer("ReleaseL")
	end
end)
