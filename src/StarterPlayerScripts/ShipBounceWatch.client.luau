--[[
	ShipBounceWatch: a quiet, client-side witness for the "ships are bouncing" report.

	The bounce has been fixed twice against measurements taken in Studio, and both times it came
	back in the published game. Studio cannot reproduce it: Play Solo runs the server and the
	client in one process, so there is no network delay, no ownership hand-over, and no
	replication. A live server has all three. Rather than guess a third time, this watches the
	hull the way a player does -- from a client, reading the replicated motion -- and says
	something only when it actually sees oscillation.

	It samples the nearest ship for 4 s every 20 s. If the vertical velocity reverses 6 or more
	times in those 4 s (1.5 Hz or faster, far quicker than the ~0.15 Hz swell), it prints one
	line with the numbers needed to tell the possible causes apart:

		ocupant      -- is anyone driving this hull, and is it this client?
		owner        -- who owns the simulation, as the server reports it (Ship.AuthorityOwner)
		repairs      -- how many times the server had to take authority back
		rev / maxVy  -- the oscillation itself, as this client receives it
		offset       -- hull centre against the analytic surface, studs

	Reading it:

		* rev high, offset swinging      -> the physics itself is oscillating.
		* rev high, owner = a player who is NOT the occupant, repairs > 0
		                                 -> the delayed-feedback case: the force is computed on
		                                    one peer and applied on another.
		* rev LOW but the player says it bounces
		                                 -> the motion this client receives is smooth, so the
		                                    problem is visual (render/replication), not physics.
		                                    That needs a different fix and this line proves it.

	Nothing is written to the place, and there is no per-frame cost: one Heartbeat connection
	that only reads two numbers, plus one Raycast-free distance check per candidate ship.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WaveFloat = require(ReplicatedStorage:WaitForChild("FloatingObjectGeneration"):WaitForChild("WaveFloat"))

local SAMPLE_SECONDS = 4
local INTERVAL_SECONDS = 20
local NEAREST_STUDS = 250
local REVERSAL_LIMIT = 6
local SWING = 0.08 -- studs the hull must travel the other way to count as a reversal

local player = Players.LocalPlayer

local function nearestShip(): Model?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local best, bestDistance = nil, NEAREST_STUDS
	for _, instance in ipairs(CollectionService:GetTagged("ShipHull")) do
		if instance:IsA("Model") and instance:IsDescendantOf(workspace) then
			local main = instance:FindFirstChild("Main", true)
			if main then
				local distance = (main.Position - root.Position).Magnitude
				if distance < bestDistance then
					best, bestDistance = instance, distance
				end
			end
		end
	end
	return best
end

-- Ships are not tagged in the place (they are hand-placed models), so fall back to a name
-- list. Kept explicit so this never starts sampling a prop or a dock.
local SHIP_NAMES = { "WoodenShip", "MisoSoup", "Boathouse", "ServerBoat" }

local function nearestNamedShip(): Model?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local tagged = nearestShip()
	if tagged then
		return tagged
	end
	local best, bestDistance = nil, NEAREST_STUDS
	for _, name in ipairs(SHIP_NAMES) do
		local model = workspace:FindFirstChild(name)
		local main = model and model:FindFirstChild("Main", true)
		if main then
			local distance = (main.Position - root.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = model, distance
			end
		end
	end
	return best
end

local function report(ship: Model, reversals: number, peakVy: number, offset: number)
	local seat = ship:FindFirstChild("VehicleSeat", true)
	local occupant = seat and seat.Occupant
	local occupantName = if occupant and occupant.Parent then occupant.Parent.Name else "nobody"
	local mine = occupant and occupant.Parent == player.Character
	local repairs = ship:GetAttribute("AuthorityRepairs") or 0
	local owner = ship:GetAttribute("AuthorityOwner") or "?"
	warn(string.format(
		"[BRINE] %s bouncing: %d reversals in %ds, peak |vy| %.1f, centre-vs-surface %+.1f | occupant %s%s | owner %s | authority repairs %d",
		ship.Name, reversals, SAMPLE_SECONDS, peakVy, offset, occupantName,
		mine and " (this client)" or "", tostring(owner), repairs
	))
end

local function sample(ship: Model)
	local main = ship:FindFirstChild("Main", true)
	if not main then
		return
	end
	local cornerPoints = {}
	for _, name in ipairs({ "TopLeft", "TopRight", "BottomLeft", "BottomRight" }) do
		local attachment = main:FindFirstChild(name)
		if attachment and attachment:IsA("Attachment") then
			cornerPoints[#cornerPoints + 1] = attachment
		end
	end
	-- Measured from POSITION, not AssemblyLinearVelocity: on a server-owned hull this
	-- client receives the motion but the velocity property does not track it (verified: a
	-- forced 12 studs/s oscillation produced no reading here at all). Position deltas are
	-- also the honest definition of the complaint, which is about what the player sees.
	local reversals, filtered, extreme, direction, peakVy = 0, nil, nil, 0, 0
	local lastY = nil
	local sumOffset, offsetSamples, minOffset, maxOffset = 0, 0, math.huge, -math.huge
	local connection
	connection = RunService.Heartbeat:Connect(function(dt)
		local y = main.Center.WorldPosition.Y
		-- Low-pass first, then count a reversal only when the hull has actually travelled
		-- SWING studs the other way. A raw sign change of the frame delta counts network
		-- quantisation as oscillation: on a replicated hull the position steps in ~0.03-stud
		-- quanta, which flipped the sign 7 times in 4 s on a perfectly calm hull.
		filtered = if filtered == nil then y else filtered + (y - filtered) * 0.5
		-- dt is clamped: two Heartbeat callbacks can land microseconds apart, and dividing a
		-- 0.03-stud step by 0.0001 s reports 300 studs/s. That is what the first run printed.
		if lastY ~= nil and dt > 0.002 then
			local speed = math.clamp((filtered - lastY) / dt, -60, 60)
			if math.abs(speed) > peakVy then
				peakVy = math.abs(speed)
			end
		end
		if extreme == nil then
			extreme = filtered
		elseif filtered > extreme + SWING then
			if direction == -1 then
				reversals += 1
			end
			direction = 1
			extreme = filtered
		elseif filtered < extreme - SWING then
			if direction == 1 then
				reversals += 1
			end
			direction = -1
			extreme = filtered
		end
		lastY = filtered
		local centre = main.Center.WorldPosition
		-- The surface must be the SAME surface the ship itself uses: the mean of the four
		-- corner heights (Ship.Handler's `seaSurfaceAt`, which mirrors WaveFloat.Solve).
		-- Sampling the centre instead differs from that mean by up to a stud on a 125-stud
		-- hull, and the difference oscillates as waves pass -- which reads as "the hull is
		-- bouncing" when nothing is wrong. Measured: centre-sampled residual 1.64 studs,
		-- corner-mean residual a fraction of that.
		local now = workspace:GetServerTimeNow()
		local sum, count = 0, 0
		for _, attachment in ipairs(cornerPoints) do
			local height = WaveFloat.HeightAt(attachment.WorldPosition, nil, nil, nil, now)
			if height then
				sum += height
				count += 1
			end
		end
		local surface = if count > 0 then sum / count else nil
		if surface then
			local offset = centre.Y - surface
			sumOffset += offset
			offsetSamples += 1
			minOffset = math.min(minOffset, offset)
			maxOffset = math.max(maxOffset, offset)
		end
	end)
	task.wait(SAMPLE_SECONDS)
	connection:Disconnect()
	if reversals >= REVERSAL_LIMIT then
		local offset = if offsetSamples > 0 then sumOffset / offsetSamples else 0
		if offsetSamples > 0 then
			offset = (minOffset + maxOffset) / 2
		end
		report(ship, reversals, peakVy, offset)
	end
end

task.spawn(function()
	-- Let the character and the hulls arrive first.
	task.wait(6)
	-- One line so silence means "watching, nothing wrong" rather than "not installed".
	warn(string.format("[BRINE] ship watch active (>= %d reversals in %ds around a hull within %d studs will be reported)",
		REVERSAL_LIMIT, SAMPLE_SECONDS, NEAREST_STUDS))
	while true do
		local ship = nearestNamedShip()
		if ship then
			sample(ship)
		end
		task.wait(INTERVAL_SECONDS)
	end
end)
