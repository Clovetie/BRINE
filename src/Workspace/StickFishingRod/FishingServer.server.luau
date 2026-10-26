-- FishingServer: authoritative cast, bobber water physics, bite timing, reel-in, throw
-- and grab for the StickFishingRod tool. FishingClient only shows the viewport and
-- sends input. Every tuning value lives in FishingConfig.
--
-- Bobber: anchored, never resized, never welded. Scripted motion only:
--   * flight: a parabolic arc from the rod tip to the water spot
--   * floating: a critically damped spring holds it on the sea surface (yaw only)
--   * caught: it follows the fish's BobberPos attachment
--
-- Rope: RopeConstraint between RodLineAnchor (anchored, follows the rod tip) and the
-- bobber. Both ends are anchored, so the rope applies no force to the rod or the player.
--
-- Caught fish: reeled up to the player (anchored, scripted path), released behind the
-- player with physics, then it lands on the water and rides the surface (anchored).
-- Grab: a built-in DragDetector (Geometric). While held, the floating code skips the
-- fish entirely (no water spring, no physics) and its collision stays off.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local WaveFloat = require(ReplicatedStorage.FloatingObjectGeneration.WaveFloat)
local FishPose = require(script.Parent.FishPose)
local FishingSounds = require(ReplicatedStorage.Fishing.FishingSounds)
local Config = require(script.Parent.FishingConfig)

local tool = script.Parent
local rod = tool:WaitForChild("Rod")
local tip = rod:WaitForChild("FishingRodTip")
local bobber = rod:WaitForChild("Bobber")
local bobberPoint = bobber:WaitForChild("BobberPoint")
local rope = rod:WaitForChild("RopeConstraint")
local anchor = tool:WaitForChild("RodLineAnchor")
local anchorAttach = anchor:WaitForChild("AnchorAttach")
local commonFish = ServerStorage:WaitForChild("Fish"):WaitForChild("Common")

local CAST = Config.Cast
local BITE = Config.Bite
local CATCH = Config.Catch
local FLOAT = Config.Float
local GRAB = Config.Grab

local SLACK = 2              -- extra rope length beyond the bobber distance
local REST_LIFT = 0.4        -- rest pose: bobber this far above the rod tip
local bobberYaw = 0

-- Remotes --------------------------------------------------------------------
local remotes = tool:FindFirstChild("FishingRemotes")
if remotes == nil then
	remotes = Instance.new("Folder")
	remotes.Name = "FishingRemotes"
	remotes.Parent = tool
end
local fishEvent = remotes:FindFirstChild("FishEvent") or Instance.new("RemoteEvent")
fishEvent.Name = "FishEvent"
fishEvent.Parent = remotes
local action = remotes:FindFirstChild("Action") or Instance.new("RemoteEvent")
action.Name = "Action"
action.Parent = remotes

-- Shared folders -------------------------------------------------------------
local previews = ReplicatedStorage:FindFirstChild("FishingPreviews")
if previews == nil then
	previews = Instance.new("Folder")
	previews.Name = "FishingPreviews"
	previews.Parent = ReplicatedStorage
end

local caughtFolder = workspace:FindFirstChild("CaughtFish")
if caughtFolder == nil then
	caughtFolder = Instance.new("Folder")
	caughtFolder.Name = "CaughtFish"
	caughtFolder.Parent = workspace
end

-- Bobber: anchored, no physics joints, size untouched ------------------------
bobber.Anchored = true
bobber.CanCollide = false
bobber.CanQuery = false
bobber.CanTouch = false
bobber.Massless = true

-- Effects: the bobber carries a splash and a bubble emitter (created once, reused).
local function makeEmitter(parent: Instance, name: string, props: { [string]: any }): ParticleEmitter
	local e = parent:FindFirstChild(name)
	if e == nil or not e:IsA("ParticleEmitter") then
		e = Instance.new("ParticleEmitter")
		e.Name = name
		e.Parent = parent
	end
	e.Enabled = false
	e.Rate = 0
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	for k, v in pairs(props) do
		(e :: any)[k] = v
	end
	return e
end

local fxAttach = bobber:FindFirstChild("FxAttach")
if fxAttach == nil then
	fxAttach = Instance.new("Attachment")
	fxAttach.Name = "FxAttach"
	fxAttach.Parent = bobber
end
local splashFx = makeEmitter(fxAttach, "Splash", {
	Lifetime = NumberRange.new(0.4, 0.8),
	Speed = NumberRange.new(6, 11),
	SpreadAngle = Vector2.new(70, 70),
	EmissionDirection = Enum.NormalId.Top,
	Color = ColorSequence.new(Color3.fromRGB(200, 235, 255)),
	Size = NumberSequence.new(0.5, 0.1),
	Transparency = NumberSequence.new(0.2, 1),
	Acceleration = Vector3.new(0, -25, 0),
	LightEmission = 0.5,
})
local bubbleFx = makeEmitter(fxAttach, "Bubbles", {
	Lifetime = NumberRange.new(0.8, 1.4),
	Speed = NumberRange.new(2, 4),
	SpreadAngle = Vector2.new(20, 20),
	EmissionDirection = Enum.NormalId.Top,
	Color = ColorSequence.new(Color3.fromRGB(230, 250, 255)),
	Size = NumberSequence.new(0.25, 0.15),
	Transparency = NumberSequence.new(0.3, 1),
})

-- Rope: both ends anchored, so it cannot pull on anything physical.
rope.Attachment0 = anchorAttach
rope.Attachment1 = bobberPoint
rope.Enabled = false
rope.Visible = false

-- State ----------------------------------------------------------------------
-- idle -> flying -> floating -> biting -> hook -> caught (reel) -> idle
local state = "idle"
local castId = 0
local castPlayer: Player? = nil
local preview: Model? = nil
local biteTemplate: Model? = nil
local biteScale = 1

local flyStart = Vector3.zero
local flyGoal = Vector3.zero
local flyT0 = 0
local flyDur = 1
local flyArc = 0
local flyRopeStart = 2
local flyRopeGoal = 2

local bobX, bobY, bobZ = 0, 0, 0
local bobVy = 0
local catchMouth: Attachment? = nil

local function ownerOf(): Player?
	local parent = tool.Parent
	if parent and parent:IsA("Backpack") then
		parent = parent.Parent
	end
	if parent and parent:IsA("Player") then
		return parent
	end
	if parent and parent:IsA("Model") then
		return Players:GetPlayerFromCharacter(parent)
	end
	return nil
end

local function hrpOf(player: Player): BasePart?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function seaAt(pos: Vector3): number
	return WaveFloat.HeightAt(pos, nil, nil, "ANALYTIC", workspace:GetServerTimeNow()) or BITE.FallbackSea
end

local function clearPreview()
	if preview then
		preview:Destroy()
		preview = nil
	end
end

local function placeBobber(pos: Vector3)
	bobber.CFrame = CFrame.new(pos) * CFrame.Angles(0, bobberYaw, 0)
end

local function setRest()
	state = "idle"
	catchMouth = nil
	rope.Enabled = false
	rope.Visible = false
	bobber.AssemblyLinearVelocity = Vector3.zero
	bobber.AssemblyAngularVelocity = Vector3.zero
end

local function resetRod(reason: string?)
	castId += 1
	clearPreview()
	setRest()
	if reason and castPlayer then
		fishEvent:FireClient(castPlayer, "Cancel", reason)
	end
	castPlayer = nil
end

-- Fish helpers ----------------------------------------------------------------
local function setAnchored(fish: Model, on: boolean)
	for _, p in ipairs(fish:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = on
		end
	end
end

-- Particle emitters on the fish (its own wriggle sparkle) on or off.
local function setEmitters(fish: Model, on: boolean)
	for _, e in ipairs(fish:GetDescendants()) do
		if e:IsA("ParticleEmitter") then
			e.Enabled = on
		end
	end
end

-- A caught fish is dead: black eyes, smooth plastic. UsePartColor must be on for a
-- UnionOperation to show its Color at all.
local function markDead(fish: Model)
	local eyes = fish:FindFirstChild("Eyes", true)
	if eyes and eyes:IsA("UnionOperation") then
		eyes.UsePartColor = true
		eyes.Color = Color3.new(0, 0, 0)
		eyes.Material = Enum.Material.SmoothPlastic
	elseif eyes and eyes:IsA("BasePart") then
		eyes.Color = Color3.new(0, 0, 0)
		eyes.Material = Enum.Material.SmoothPlastic
	end
end

-- Collision: captured on first use, off while held or reeling, restored on release.
local function captureCollide(f: any)
	f.collide = {}
	for _, p in ipairs(f.fish:GetDescendants()) do
		if p:IsA("BasePart") then
			f.collide[p] = p.CanCollide
		end
	end
end

local function collisionOff(f: any)
	if f.collide == nil then
		captureCollide(f)
	end
	for p in pairs(f.collide) do
		if p.Parent then
			p.CanCollide = false
		end
	end
end

local function collisionRestore(f: any)
	if f.collide then
		for p, v in pairs(f.collide) do
			if p.Parent then
				p.CanCollide = v
			end
		end
		f.collide = nil
	end
end

-- Caught fish: reel, release, float -------------------------------------------
-- Entries: { fish, primary, state, player, t0, start, yaw, collide, x, z, dd, dragging, ... }
-- States: "reel" (anchored, pulled up to the player), "air" (physics),
-- "water" (anchored, rides the surface). A dragging flag overrides all of them.
local floaters: { any } = {}

-- Hold point: in front of the player, above the head, so the fish clears them on release.
local function holdPoint(hrp: BasePart): Vector3
	local look = hrp.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.001 then
		flat = Vector3.new(0, 0, -1)
	end
	return hrp.Position + flat.Unit * CATCH.HoldFront + Vector3.new(0, CATCH.HoldHeight, 0)
end

local function releaseFish(f: any)
	local fish = f.fish
	local root = f.primary
	fish:SetAttribute("Reeling", nil)
	setAnchored(fish, false)
	collisionRestore(f)

	-- Thrown behind the player: away from where they face.
	local back = Vector3.new(0, 0, 1)
	local hrp = hrpOf(f.player)
	if hrp then
		local look = hrp.CFrame.LookVector
		local flat = Vector3.new(-look.X, 0, -look.Z)
		if flat.Magnitude > 0.001 then
			back = flat.Unit
		end
	end
	root.AssemblyLinearVelocity = back * CATCH.ThrowBack + Vector3.new(0, CATCH.ThrowUp, 0)
	root.AssemblyAngularVelocity = Vector3.new(math.random() * 4 - 2, math.random() * 4 - 2, math.random() * 4 - 2)
	f.state = "air"
	f.dd.Enabled = true

	if castPlayer == f.player then
		castPlayer = nil
	end
	setRest()
end

-- Grab: Roblox's built-in DragDetector ----------------------------------------
-- Geometric response: the engine moves the fish exactly where the cursor puts it. While
-- a player holds it, the floating code skips it, so its floating physics are off.
-- CanCollide stays off while held; it is restored on release.
local DRAG_STYLE = Enum.DragDetectorDragStyle[GRAB.DragStyle]

local function onDragStart(f: any, player: Player)
	if f.dragging or f.state == nil or f.state == "reel" then
		return
	end
	local hrp = hrpOf(player)
	if hrp == nil then
		return
	end
	f.dragging = true
	f.dragPlayer = player
	f.lastGood = CFrame.identity
	f.fish:SetAttribute("DraggedBy", player.Name)
	collisionOff(f)

	-- Keep the held fish within GRAB.Range of its holder. Beyond that it stops where it was.
	f.constraint = f.dd:AddConstraintFunction(1, function(proposed: CFrame): CFrame
		local holder = hrpOf(player)
		if holder == nil then
			return f.lastGood
		end
		local world = f.dd:GetReferenceFrame() * proposed
		if (world.Position - holder.Position).Magnitude > GRAB.Range then
			return f.lastGood
		end
		f.lastGood = proposed
		return proposed
	end)
end

local function onDragEnd(f: any)
	if not f.dragging then
		return
	end
	f.dragging = false
	f.dragPlayer = nil
	if f.constraint then
		f.constraint:Disconnect()
		f.constraint = nil
	end
	if f.fish.Parent then
		f.fish:SetAttribute("DraggedBy", nil)
	end
	collisionRestore(f)
	-- Released in the air: back to physics. Released on the surface: the next frame
	-- sees it on the water and anchors it again.
	f.state = "air"
	setAnchored(f.fish, false)
end

local function makeDragDetector(f: any): DragDetector
	local dd = Instance.new("DragDetector")
	dd.ResponseStyle = Enum.DragDetectorResponseStyle.Geometric
	dd.DragStyle = DRAG_STYLE
	dd.MaxActivationDistance = GRAB.Range
	dd.Enabled = false -- off during the reel; on once the fish is released
	dd.Parent = f.fish
	dd.DragStart:Connect(function(player: Player)
		onDragStart(f, player)
	end)
	dd.DragEnd:Connect(function()
		onDragEnd(f)
	end)
	return dd
end

local function updateFloaters()
	for i = #floaters, 1, -1 do
		local f = floaters[i]
		local fish = f.fish
		local root = f.primary
		if fish.Parent == nil or root.Parent == nil then
			table.remove(floaters, i)
		elseif f.dragging then
			-- Held by the DragDetector: no floating, no reel. Release if the holder has gone.
			if f.dragPlayer == nil or f.dragPlayer.Parent == nil then
				onDragEnd(f)
			end
		elseif f.state == "reel" then
			-- Pull the fish along a smooth arc to the hold point. The hold point follows the
			-- player, so this still works on a moving ship or high up.
			local hrp = hrpOf(f.player)
			local alpha = math.clamp((os.clock() - f.t0) / CATCH.ReelTime, 0, 1)
			local e = alpha * alpha * (3 - 2 * alpha)
			local hold = if hrp then holdPoint(hrp) else f.start
			local mid = (f.start + hold) / 2 + Vector3.new(0, CATCH.ReelArc, 0)
			local pos = (1 - e) * (1 - e) * f.start + 2 * (1 - e) * e * mid + e * e * hold
			fish:PivotTo(CFrame.new(pos) * CFrame.Angles(0, f.yaw, 0) * root.CFrame:Inverse() * fish:GetPivot())
			if alpha >= 1 then
				releaseFish(f)
			end
		else
			local pos = root.Position
			local sea = seaAt(Vector3.new(pos.X, 0, pos.Z))
			if f.state ~= "water" then
				if pos.Y <= sea + FLOAT.EnterBand and root.AssemblyLinearVelocity.Y <= 0 then
					-- Came down onto the water: stop here and ride the surface.
					f.state = "water"
					f.x = pos.X
					f.z = pos.Z
					local _, yaw = root.CFrame:ToOrientation()
					f.yaw = yaw
					root.AssemblyLinearVelocity = Vector3.zero
					root.AssemblyAngularVelocity = Vector3.zero
					setAnchored(fish, true)
				else
					f.state = "air"
				end
			end

			if f.state == "water" then
				local surface = seaAt(Vector3.new(f.x, 0, f.z))
				local desired = CFrame.new(f.x, surface - FLOAT.Depth, f.z) * CFrame.Angles(0, f.yaw, 0)
				fish:PivotTo(desired * root.CFrame:Inverse() * fish:GetPivot())
			end
		end
	end
end

-- Bite -----------------------------------------------------------------------
local function catchFish(player: Player, id: number)
	if id ~= castId or state ~= "hook" or biteTemplate == nil then
		return
	end
	local hrp = hrpOf(player)
	if hrp == nil then
		resetRod("NoCharacter")
		return
	end

	local template = biteTemplate :: Model
	local fish = template:Clone()
	fish:ScaleTo(biteScale)
	local primary = fish.PrimaryPart
	if primary == nil then
		fish:Destroy()
		resetRod("BadFish")
		return
	end

	local flat = Vector3.new(bobberPoint.WorldPosition.X - hrp.Position.X, 0, bobberPoint.WorldPosition.Z - hrp.Position.Z)
	local facing = Vector3.new(0, 0, -1)
	if flat.Magnitude > 0.001 then
		facing = flat.Unit
	end
	local pose = FishPose.Target(fish, bobberPoint.WorldPosition, facing)
	if pose then
		fish:PivotTo(pose)
	end

	-- Hold every part to the primary, then anchor the whole fish for the reel.
	for _, p in ipairs(fish:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
			if p ~= primary and #p:GetJoints() == 0 then
				local w = Instance.new("WeldConstraint")
				w.Part0 = primary
				w.Part1 = p
				w.Parent = p
			end
		end
	end
	fish.Parent = caughtFolder

	clearPreview()
	fish:SetAttribute("Caught", true)
	fish:SetAttribute("Dead", true)
	fish:SetAttribute("Reeling", true)
	markDead(fish)
	setEmitters(fish, false) -- the fish's emitter stops once it is caught

	-- The bobber rides on the fish's bite point during the reel.
	state = "caught"
	catchMouth = fish:FindFirstChild("BobberPos", true) :: Attachment
	rope.Enabled = false
	rope.Visible = false

	local _, yaw = primary.CFrame:ToOrientation()
	local f = {
		fish = fish,
		primary = primary,
		state = "reel",
		player = player,
		t0 = os.clock(),
		start = primary.Position,
		yaw = yaw,
		dragging = false,
	}
	table.insert(floaters, f)
	f.dd = makeDragDetector(f)
	collisionOff(f)

	-- Splash and catch sound come from the fish itself.
	local splashAt = Instance.new("Attachment")
	splashAt.Parent = primary
	local burst = splashFx:Clone()
	burst.Parent = splashAt
	burst:Emit(30)
	task.delay(2, function()
		splashAt:Destroy()
	end)
	FishingSounds.Play(primary, FishingSounds.Caught, 1, 90)
	fishEvent:FireClient(player, "Caught", template.Name)
end

local function startBite(player: Player, id: number)
	if id ~= castId or state ~= "floating" then
		return
	end

	local list = {}
	for _, c in ipairs(commonFish:GetChildren()) do
		if c:IsA("Model") and c.PrimaryPart then
			table.insert(list, c)
		end
	end
	if #list == 0 then
		resetRod("NoFish")
		return
	end

	local template = list[math.random(#list)]
	local scale = BITE.ScaleMin + math.random() * (BITE.ScaleMax - BITE.ScaleMin)

	-- Client-visible copy for the viewport (same scale as the real catch).
	local pv = template:Clone()
	pv:ScaleTo(scale)
	for _, p in ipairs(pv:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
		end
	end
	clearPreview()
	pv.Name = tostring(player.UserId)
	pv.Parent = previews
	preview = pv

	biteTemplate = template
	biteScale = scale
	state = "biting"
	fishEvent:FireClient(player, "Bite", template.Name, scale, BITE.Approach)

	-- Contact: the fish has taken the bait. The player has HookWindow seconds to click.
	task.delay(BITE.Approach, function()
		if id ~= castId or state ~= "biting" then
			return
		end
		state = "hook"
		FishingSounds.Play(bobber, FishingSounds.TookBait, 1, 80)
		bubbleFx:Emit(12)
		task.delay(BITE.HookWindow, function()
			if id ~= castId or state ~= "hook" then
				return
			end
			-- Missed the hook: the fish gets away.
			resetRod("GotAway")
		end)
	end)
end

-- Cast -----------------------------------------------------------------------
local function onCast(player: Player, target: any)
	if ownerOf() ~= player then
		return
	end
	-- Always answer a refused cast, so the client never waits on a bite that will not come.
	if state ~= "idle" then
		fishEvent:FireClient(player, "Cancel", "Busy")
		return
	end
	if typeof(target) ~= "Vector3" or hrpOf(player) == nil then
		fishEvent:FireClient(player, "Cancel", "NoCharacter")
		return
	end

	local origin = tip.WorldPosition
	local delta = target - origin
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude < CAST.MinDistance then
		fishEvent:FireClient(player, "Cancel", "TooClose")
		return
	end
	if flat.Magnitude > CAST.Range then
		flat = flat.Unit * CAST.Range
	end

	-- The landing spot must be on the water surface, not on land.
	local goalXZ = Vector3.new(origin.X + flat.X, 0, origin.Z + flat.Z)
	local sea = seaAt(goalXZ)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character :: Instance, tool, caughtFolder }
	local ray = workspace:Raycast(Vector3.new(goalXZ.X, sea + 200, goalXZ.Z), Vector3.new(0, -400, 0), params)
	if ray and ray.Position.Y > sea + CAST.LandCheck then
		fishEvent:FireClient(player, "Cancel", "NoWater")
		return
	end

	castId += 1
	local id = castId
	state = "flying"
	castPlayer = player

	flyStart = origin
	flyGoal = Vector3.new(goalXZ.X, sea + Config.Bite.WaterLine, goalXZ.Z)
	local dist = (flyGoal - flyStart).Magnitude
	flyDur = math.clamp(dist / 45, 0.5, 1.2)
	flyArc = math.max(6, dist * 0.25)
	flyT0 = os.clock()
	flyRopeStart = 2
	flyRopeGoal = dist + SLACK
	rope.Enabled = true
	rope.Visible = true
	rope.Length = flyRopeStart
	placeBobber(origin)
	FishingSounds.Play(tip, FishingSounds.Cast, 0.9, 60)

	task.delay(flyDur + 0.05, function()
		if id ~= castId or state ~= "flying" then
			return
		end
		state = "floating"
		bobX, bobY, bobZ = flyGoal.X, flyGoal.Y, flyGoal.Z
		bobVy = 0
		-- The bobber touches the water: splash and water sound.
		splashFx:Emit(24)
		FishingSounds.Play(bobber, FishingSounds.BobberSplash, 0.9, 60)
		local wait = BITE.WaitMin + math.random() * (BITE.WaitMax - BITE.WaitMin)
		task.delay(wait, function()
			startBite(player, id)
		end)
	end)
end

-- Wiring ---------------------------------------------------------------------
action.OnServerEvent:Connect(function(player: Player, kind: any, arg: any)
	if kind == "Cast" then
		onCast(player, arg)
	elseif kind == "Hook" then
		-- Only counts once the fish has taken the bait, and only for the player who cast.
		if state == "hook" and castPlayer == player then
			FishingSounds.Play(bobber, FishingSounds.HookClick, 1, 60)
			catchFish(player, castId)
		end
	end
end)

tool.Unequipped:Connect(function()
	if state == "flying" or state == "floating" or state == "biting" then
		resetRod("Unequipped")
	end
end)

Players.PlayerRemoving:Connect(function(player)
	for _, f in ipairs(floaters) do
		if f.dragPlayer == player then
			onDragEnd(f)
		end
	end
	if castPlayer == player then
		resetRod()
	end
end)

RunService.Heartbeat:Connect(function(dt)
	anchor.CFrame = CFrame.new(tip.WorldPosition)
	updateFloaters()

	if state == "idle" then
		-- Yaw-only, like the water pose: the bobber does not inherit the rod tip rotation.
		bobber.CFrame = CFrame.new(tip.WorldPosition + Vector3.new(0, REST_LIFT, 0)) * CFrame.Angles(0, bobberYaw, 0)
	elseif state == "flying" then
		local alpha = math.clamp((os.clock() - flyT0) / flyDur, 0, 1)
		local pos = flyStart:Lerp(flyGoal, alpha) + Vector3.new(0, flyArc * 4 * alpha * (1 - alpha), 0)
		placeBobber(pos)
		rope.Length = flyRopeStart + (flyRopeGoal - flyRopeStart) * alpha
	elseif state == "floating" or state == "biting" then
		-- Water physics: critically damped spring onto the sea surface, yaw-only orientation.
		local target = seaAt(Vector3.new(bobX, bobY, bobZ)) + BITE.WaterLine
		local acc = BITE.SpringK * (target - bobY) - BITE.SpringD * bobVy
		bobVy += acc * dt
		bobY += bobVy * dt
		placeBobber(Vector3.new(bobX, bobY, bobZ))
		rope.Length = flyRopeGoal
	elseif state == "caught" and catchMouth then
		placeBobber(catchMouth.WorldPosition)
	end

end)

-- Start in the rest pose.
setRest()
