--!nonstrict
--!optimize 2

-- ROADMAP 4.3: player positions for activation and despawn distance checks.
-- Reads character roots only; holds no generator state.

local Players = game:GetService("Players")

local Proximity = {}

local function getPlayerRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function getPlayerRoots(): { BasePart }
	local roots = {}
	for _, player in Players:GetPlayers() do
		local root = getPlayerRoot(player)
		if root then
			table.insert(roots, root)
		end
	end
	return roots
end

local function isAnyPlayerWithin(centerPos: Vector3, radius: number): boolean
	local radiusSq = radius * radius
	for _, player in Players:GetPlayers() do
		local root = getPlayerRoot(player)
		if root then
			local dx = root.Position.X - centerPos.X
			local dz = root.Position.Z - centerPos.Z
			if dx * dx + dz * dz <= radiusSq then
				return true
			end
		end
	end
	return false
end

local function distanceSqToNearestPlayer(centerPos: Vector3): number
	local best = math.huge
	for _, player in Players:GetPlayers() do
		local root = getPlayerRoot(player)
		if root then
			local dx = root.Position.X - centerPos.X
			local dz = root.Position.Z - centerPos.Z
			local distSq = dx * dx + dz * dz
			if distSq < best then
				best = distSq
			end
		end
	end
	return best
end

Proximity.getPlayerRoot = getPlayerRoot
Proximity.getPlayerRoots = getPlayerRoots
Proximity.isAnyPlayerWithin = isAnyPlayerWithin
Proximity.distanceSqToNearestPlayer = distanceSqToNearestPlayer

return Proximity
