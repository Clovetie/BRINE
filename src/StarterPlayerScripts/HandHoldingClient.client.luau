--!nonstrict
-- Hand-Holding Client
-- The client only:
--   1. Tracks whether the local player is holding L.
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

-- True while the player is physically holding L. Prevents duplicate press
-- events from keyboard repeat.
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
	if gameProcessed then
		return
	end

	if input.KeyCode == Enum.KeyCode.L and not holdingL then
		holdingL = true
		local target = getBestTarget()
		remoteEvent:FireServer("PressL", target)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.L and holdingL then
		holdingL = false
		remoteEvent:FireServer("ReleaseL")
	end
end)

-- If the keyboard loses focus, treat L as released so the server never keeps
-- a stale offer/connection open because InputEnded was missed.
local function resetHoldIfKeyNotDown()
	if not UserInputService:IsKeyDown(Enum.KeyCode.L) and holdingL then
		holdingL = false
		remoteEvent:FireServer("ReleaseL")
	end
end

UserInputService.WindowFocused:Connect(resetHoldIfKeyNotDown)
UserInputService.WindowLostFocus:Connect(resetHoldIfKeyNotDown)
