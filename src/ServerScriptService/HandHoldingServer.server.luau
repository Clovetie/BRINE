--!nonstrict
-- Hand-Holding Server
-- Authoritative state machine for R15 players holding hands using IKControl.
--
-- Messages the client may send:
--   ("PressL",   targetPlayer or nil)  -- player is now holding L
--   ("ReleaseL", nil)                  -- player is no longer holding L
--
-- The server validates every offer, acceptance, distance, and character check.
-- IK controls are created on the server so the resulting pose replicates to
-- every client that can see the characters.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local handHoldingFolder = ReplicatedStorage:WaitForChild("HandHolding")
local remoteEvent = handHoldingFolder:WaitForChild("HandHoldingEvent") :: RemoteEvent
local config = require(handHoldingFolder:WaitForChild("HandHoldingConfig"))

local MAX_DISTANCE = config.MAX_DISTANCE
local OFFER_TIMEOUT = config.OFFER_TIMEOUT
local IK_FADE_TIME = config.IK_FADE_TIME
local IK_SMOOTH_TIME = config.IK_SMOOTH_TIME
local VALIDATION_INTERVAL = config.VALIDATION_INTERVAL

-- State:
--   Idle      -> no offer, no connection
--   Offering  -> offers[offerer] = { target, token }
--   Accepted  -> momentary during a mutual press, immediately becomes Holding
--   Holding   -> connectionByPlayer[player] = active connection
--   Released  -> connection.ending = true (IK fades out, then cleanup)
local offers = {}
local connections = {}
local connectionByPlayer = {}

----------------------------------------------------------------------------
-- Character helpers
----------------------------------------------------------------------------

local function getCharacter(player)
	if not player then
		return nil
	end
	return player.Character
end

local function isValidR15Character(player)
	local character = getCharacter(player)
	if not character then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	if humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return false
	end

	for _, partName in ipairs({
		"HumanoidRootPart",
		"UpperTorso",
		"LowerTorso",
		"Head",
		"LeftUpperArm",
		"LeftHand",
		"RightUpperArm",
		"RightHand",
	}) do
		if not character:FindFirstChild(partName) then
			return false
		end
	end

	return true
end

local function getCharacterRoot(player)
	local character = getCharacter(player)
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart")
end

local function distanceBetween(a, b)
	local rootA = getCharacterRoot(a)
	local rootB = getCharacterRoot(b)
	if not rootA or not rootB then
		return nil
	end
	return (rootA.Position - rootB.Position).Magnitude
end

local function getActiveConnection(player)
	local connection = connectionByPlayer[player]
	if connection and not connection.ending then
		return connection
	end
	return nil
end

----------------------------------------------------------------------------
-- Offer helpers
----------------------------------------------------------------------------

local offerTokenCounter = 0

local function cancelOffer(player)
	offers[player] = nil
end

local function cancelOffersToPlayer(player)
	local toRemove = {}
	for offerer, offer in pairs(offers) do
		if offer.target == player then
			table.insert(toRemove, offerer)
		end
	end
	for _, offerer in ipairs(toRemove) do
		offers[offerer] = nil
	end
end

local function addOffer(offerer, target)
	offerTokenCounter = offerTokenCounter + 1
	local token = offerTokenCounter
	offers[offerer] = {
		target = target,
		token = token,
	}

	task.delay(OFFER_TIMEOUT, function()
		local current = offers[offerer]
		if current and current.token == token then
			offers[offerer] = nil
		end
	end)
end

----------------------------------------------------------------------------
-- Connection helpers + IK setup
----------------------------------------------------------------------------

local function destroySetup(setup)
	if not setup then
		return
	end
	if setup.ik then
		setup.ik:Destroy()
		setup.ik = nil
	end
	if setup.target then
		setup.target:Destroy()
		setup.target = nil
	end
end

local function forceDropConnection(connection)
	if not connection then
		return
	end

	destroySetup(connection.setupA)
	destroySetup(connection.setupB)

	if connectionByPlayer[connection.a] == connection then
		connectionByPlayer[connection.a] = nil
	end
	if connectionByPlayer[connection.b] == connection then
		connectionByPlayer[connection.b] = nil
	end

	connections[connection] = nil
end

local function createIkSetup(character, side)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local hand = character:FindFirstChild(side .. "Hand")
	local upperArm = character:FindFirstChild(side .. "UpperArm")

	if not humanoid or not rootPart or not hand or not upperArm then
		return nil
	end

	local target = Instance.new("Attachment")
	target.Name = "HandHolding_" .. side .. "Target"
	target.Parent = rootPart
	target.Position = rootPart.CFrame:Inverse() * hand.Position

	local ik = Instance.new("IKControl")
	ik.Name = "HandHolding_" .. side .. "_IK"
	ik.Type = Enum.IKControlType.Position
	ik.EndEffector = hand
	ik.ChainRoot = upperArm
	ik.Target = target
	ik.SmoothTime = IK_SMOOTH_TIME
	ik.Priority = 100
	ik.Weight = 0
	ik.Enabled = false
	ik.Parent = humanoid

	return {
		ik = ik,
		target = target,
		hand = hand,
		upperArm = upperArm,
		root = rootPart,
	}
end

local function chooseHands(charA, charB)
	local best

	for _, sideA in ipairs({ "Left", "Right" }) do
		local handA = charA:FindFirstChild(sideA .. "Hand")
		if handA then
			for _, sideB in ipairs({ "Left", "Right" }) do
				local handB = charB:FindFirstChild(sideB .. "Hand")
				if handB then
					local dist = (handA.Position - handB.Position).Magnitude
					if not best or dist < best.dist then
						best = {
							handA = handA,
							handB = handB,
							dist = dist,
						}
					end
				end
			end
		end
	end

	if not best then
		return nil, nil
	end
	return best.handA, best.handB
end

local function dropFadingConnectionForPlayer(player)
	local connection = connectionByPlayer[player]
	if connection and connection.ending then
		forceDropConnection(connection)
	end
end

local function establishConnection(a, b)
	if not isValidR15Character(a) or not isValidR15Character(b) then
		return false
	end
	if getActiveConnection(a) or getActiveConnection(b) then
		return false
	end

	local dist = distanceBetween(a, b)
	if dist == nil or dist > MAX_DISTANCE then
		return false
	end

	-- If either player is still fading out a previous connection, clean it up
	-- so the old IK never fights the new IK.
	dropFadingConnectionForPlayer(a)
	dropFadingConnectionForPlayer(b)

	local charA = getCharacter(a)
	local charB = getCharacter(b)
	local handA, handB = chooseHands(charA, charB)
	if not handA or not handB then
		return false
	end

	local sideA = handA.Name:gsub("Hand$", "")
	local sideB = handB.Name:gsub("Hand$", "")

	local setupA = createIkSetup(charA, sideA)
	local setupB = createIkSetup(charB, sideB)
	if not setupA or not setupB then
		destroySetup(setupA)
		destroySetup(setupB)
		return false
	end

	setupA.ik.Enabled = true
	setupB.ik.Enabled = true

	local connection = {
		a = a,
		b = b,
		setupA = setupA,
		setupB = setupB,
		weightA = 0,
		weightB = 0,
		ending = false,
	}

	connections[connection] = true
	connectionByPlayer[a] = connection
	connectionByPlayer[b] = connection

	cancelOffer(a)
	cancelOffer(b)
	cancelOffersToPlayer(a)
	cancelOffersToPlayer(b)

	return true
end

local function endConnection(connection)
	if not connection or connection.ending then
		return
	end
	-- The logical connection ends immediately; IK fades out gracefully.
	connection.ending = true
end

----------------------------------------------------------------------------
-- Remote event handling
----------------------------------------------------------------------------

remoteEvent.OnServerEvent:Connect(function(player, action, target)
	if action == "ReleaseL" then
		cancelOffer(player)
		local active = getActiveConnection(player)
		if active then
			endConnection(active)
		end
		return
	end

	if action ~= "PressL" then
		return
	end

	if typeof(target) ~= "Instance" or not target:IsA("Player") or target == player then
		cancelOffer(player)
		return
	end

	local targetPlayer = target

	-- A player who is already holding hands must release L first.
	local localConn = connectionByPlayer[player]
	if localConn and not localConn.ending then
		return
	end

	-- Start fresh if this player was simply fading out from a release.
	dropFadingConnectionForPlayer(player)
	dropFadingConnectionForPlayer(targetPlayer)

	-- Nobody may already be active holding hands.
	if getActiveConnection(player) or getActiveConnection(targetPlayer) then
		cancelOffer(player)
		return
	end

	if not isValidR15Character(player) or not isValidR15Character(targetPlayer) then
		cancelOffer(player)
		return
	end

	local dist = distanceBetween(player, targetPlayer)
	if dist == nil or dist > MAX_DISTANCE then
		cancelOffer(player)
		return
	end

	-- Mutual offer: the target is already offering to this player, so both are
	-- holding L. Accept and establish the connection.
	local targetOffer = offers[targetPlayer]
	if targetOffer and targetOffer.target == player then
		if establishConnection(player, targetPlayer) then
			return
		end
		cancelOffer(player)
		cancelOffer(targetPlayer)
		return
	end

	-- Otherwise store/replace this offer.
	addOffer(player, targetPlayer)
end)

----------------------------------------------------------------------------
-- Per-frame connection updates
----------------------------------------------------------------------------

RunService.Heartbeat:Connect(function(dt)
	local snapshot = {}
	for connection in pairs(connections) do
		table.insert(snapshot, connection)
	end

	for _, connection in ipairs(snapshot) do
		if connection.ending then
			-- Fade out and destroy once both sides are fully off.
			connection.weightA = math.max(0, connection.weightA - dt / IK_FADE_TIME)
			connection.weightB = math.max(0, connection.weightB - dt / IK_FADE_TIME)

			if connection.setupA.ik then
				connection.setupA.ik.Weight = connection.weightA
			end
			if connection.setupB.ik then
				connection.setupB.ik.Weight = connection.weightB
			end

			if connection.weightA <= 0 and connection.weightB <= 0 then
				forceDropConnection(connection)
			end
		else
			-- Re-validate while holding.
			if not isValidR15Character(connection.a) or not isValidR15Character(connection.b) then
				forceDropConnection(connection)
			else
				local dist = distanceBetween(connection.a, connection.b)
				if dist == nil or dist > MAX_DISTANCE then
					forceDropConnection(connection)
				else
					-- Move both targets to the midpoint between the two hands.
					local handAPos = connection.setupA.hand.Position
					local handBPos = connection.setupB.hand.Position
					local midpoint = (handAPos + handBPos) * 0.5

					connection.setupA.target.Position = connection.setupA.root.CFrame:Inverse() * midpoint
					connection.setupB.target.Position = connection.setupB.root.CFrame:Inverse() * midpoint

					connection.weightA = math.min(1, connection.weightA + dt / IK_FADE_TIME)
					connection.weightB = math.min(1, connection.weightB + dt / IK_FADE_TIME)

					if connection.setupA.ik then
						connection.setupA.ik.Enabled = true
						connection.setupA.ik.Weight = connection.weightA
					end
					if connection.setupB.ik then
						connection.setupB.ik.Enabled = true
						connection.setupB.ik.Weight = connection.weightB
					end
				end
			end
		end
	end
end)

----------------------------------------------------------------------------
-- Offer re-validation / cleanup
----------------------------------------------------------------------------

task.spawn(function()
	while true do
		task.wait(VALIDATION_INTERVAL)

		local toRemove = {}
		for offerer, offer in pairs(offers) do
			local target = offer.target
			if
				not isValidR15Character(offerer)
				or not isValidR15Character(target)
				or getActiveConnection(offerer) ~= nil
				or getActiveConnection(target) ~= nil
				or (distanceBetween(offerer, target) or math.huge) > MAX_DISTANCE
			then
				table.insert(toRemove, offerer)
			end
		end

		for _, offerer in ipairs(toRemove) do
			offers[offerer] = nil
		end
	end
end)

----------------------------------------------------------------------------
-- Player lifecycle
----------------------------------------------------------------------------

local function cleanupPlayer(player)
	forceDropConnection(connectionByPlayer[player])
	cancelOffer(player)
	cancelOffersToPlayer(player)
end

Players.PlayerRemoving:Connect(cleanupPlayer)

for _, player in ipairs(Players:GetPlayers()) do
	player.CharacterRemoving:Connect(function()
		cleanupPlayer(player)
	end)
	player.CharacterAdded:Connect(function()
		cleanupPlayer(player)
	end)
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterRemoving:Connect(function()
		cleanupPlayer(player)
	end)
	player.CharacterAdded:Connect(function()
		cleanupPlayer(player)
	end)
end)
