-- FishingServer: authoritative cast, bobber water physics, bite timing, catch and drag
-- for the StickFishingRod tool. FishingClient only shows the viewport and sends input.
--
-- Bobber: anchored, never resized, never welded. Scripted motion only:
--   * flight: a parabolic arc from the rod tip to the water spot
--   * floating: a critically damped spring holds it on the sea surface, with a
--     locked orientation (yaw only: no tilt, no roll, no sway)
--   * caught: it follows the fish's BobberPos attachment
--
-- Rope: RopeConstraint between RodLineAnchor (anchored, follows the rod tip) and the
-- bobber. Both ends are anchored, so the rope applies no force to the rod or the player.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local WaveFloat = require(ReplicatedStorage.FloatingObjectGeneration.WaveFloat)
local FishPose = require(script.Parent.FishPose)
local FishingSounds = require(ReplicatedStorage.Fishing.FishingSounds)

local tool = script.Parent
local rod = tool:WaitForChild("Rod")
local tip = rod:WaitForChild("FishingRodTip")
local bobber = rod:WaitForChild("Bobber")
local bobberPoint = bobber:WaitForChild("BobberPoint")
local rope = rod:WaitForChild("RopeConstraint")
local anchor = tool:WaitForChild("RodLineAnchor")
local anchorAttach = anchor:WaitForChild("AnchorAttach")
local commonFish = ServerStorage:WaitForChild("Fish"):WaitForChild("Common")

-- Tuning ---------------------------------------------------------------------
local CAST_RANGE = 90        -- max horizontal cast distance (studs)
local MIN_CAST = 8           -- closer than this does nothing
local BITE_WAIT_MIN = 3.5
local BITE_WAIT_MAX = 7
local APPROACH = 2.2         -- seconds for the fish to reach the bobber (viewport timing)
local HOOK_WINDOW = 3.0      -- after the bait is taken, seconds the player has to click (one click for now)
local SCALE_MIN = 0.8
local SCALE_MAX = 1.3
local THROW_BACK = 24        -- studs/s thrown behind the player
local THROW_UP = 34
local CATCH_HOLD = 1.6       -- seconds the bobber stays with the fish before returning
local WATER_LINE = 0.1       -- bobber centre rides this far above the sea surface
local SPRING_K = 25          -- water spring stiffness
local SPRING_D = 10          -- water damping (critical is about 2*sqrt(K), i.e. 10)
local LAND_CHECK = 4         -- ground this far above the sea means "not water"
local DRAG_RANGE = 22        -- how far a dragged fish may be from the player
local DRAG_LEASH = 40        -- auto-release beyond this distance
local FALLBACK_SEA = 24.98
local SLACK = 2              -- extra rope length beyond the bobber distance
local FLOAT_DEPTH = 0.5      -- caught fish: centre rides this far below the surface
local ENTER_BAND = 1.0       -- a falling caught fish lands on the water within this height

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
local bobberYaw = 0

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

-- Rest pose: bobber hangs at the rod tip (scripted, not welded).
local REST_LIFT = 0.4

-- State ----------------------------------------------------------------------
-- idle -> flying -> floating -> biting -> caught -> idle
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
	return WaveFloat.HeightAt(pos, nil, nil, "ANALYTIC", workspace:GetServerTimeNow()) or FALLBACK_SEA
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

-- Caught fish: floating -------------------------------------------------------------
-- A thrown fish falls under normal physics. Once it comes down onto the water it is
-- anchored and rides the sea surface exactly (centre FLOAT_DEPTH below the surface,
-- yaw only, no tilt), the same way the bobber does. A player drag switches it back to
-- physics for the drag; when the drag ends it rides again, or falls if it is in the air.
local floaters = {}

local function setAnchored(fish: Model, on: boolean)
	for _, p in ipairs(fish:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = on
		end
	end
end

local function updateFloaters()
	for i = #floaters, 1, -1 do
		local f = floaters[i]
		local fish = f.fish
		local root = f.primary
		if fish.Parent == nil or root.Parent == nil then
			table.remove(floaters, i)
		else
			local pos = root.Position
			local sea = seaAt(Vector3.new(pos.X, 0, pos.Z))
			if fish:GetAttribute("DraggedBy") ~= nil then
				if f.state ~= "drag" then
					f.state = "drag"
					setAnchored(fish, false)
				end
			elseif f.state ~= "water" then
				if pos.Y <= sea + ENTER_BAND and root.AssemblyLinearVelocity.Y <= 0 then
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
				local desired = CFrame.new(f.x, surface - FLOAT_DEPTH, f.z) * CFrame.Angles(0, f.yaw, 0)
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

	-- Hold every part to the primary, then release them as one rigid body.
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
	for _, p in ipairs(fish:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = false
		end
	end

	-- Thrown: physics until it comes down onto the water (see updateFloaters).
	table.insert(floaters, { fish = fish, primary = primary, state = "air" })

	-- A caught fish is dead: eyes go black and smooth plastic.
	fish:SetAttribute("Caught", true)
	fish:SetAttribute("Dead", true)
	local eyes = fish:FindFirstChild("Eyes", true)
	if eyes and eyes:IsA("BasePart") then
		eyes.Color = Color3.new(0, 0, 0)
		eyes.Material = Enum.Material.SmoothPlastic
	end

	-- The bobber rides on the fish's bite point while it is thrown.
	state = "caught"
	catchMouth = fish:FindFirstChild("BobberPos", true) :: Attachment
	rope.Enabled = false
	rope.Visible = false

	local back = -Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
	if back.Magnitude < 0.001 then
		back = Vector3.new(0, 0, 1)
	end
	back = back.Unit
	primary.AssemblyLinearVelocity = back * THROW_BACK + Vector3.new(0, THROW_UP, 0)
	primary.AssemblyAngularVelocity = Vector3.new(math.random() * 4 - 2, math.random() * 4 - 2, math.random() * 4 - 2)

	clearPreview()
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

	task.delay(CATCH_HOLD, function()
		if state ~= "caught" then
			return
		end
		castPlayer = nil
		setRest()
	end)
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
	local scale = SCALE_MIN + math.random() * (SCALE_MAX - SCALE_MIN)

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
	fishEvent:FireClient(player, "Bite", template.Name, scale, APPROACH)

	-- Contact: the fish has taken the bait. The player has HOOK_WINDOW seconds to click.
	task.delay(APPROACH, function()
		if id ~= castId or state ~= "biting" then
			return
		end
		state = "hook"
		FishingSounds.Play(bobber, FishingSounds.TookBait, 1, 80)
		bubbleFx:Emit(12)
		task.delay(HOOK_WINDOW, function()
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
	if flat.Magnitude < MIN_CAST then
		fishEvent:FireClient(player, "Cancel", "TooClose")
		return
	end
	if flat.Magnitude > CAST_RANGE then
		flat = flat.Unit * CAST_RANGE
	end

	-- The landing spot must be on the water surface, not on land.
	local goalXZ = Vector3.new(origin.X + flat.X, 0, origin.Z + flat.Z)
	local sea = seaAt(goalXZ)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character :: Instance, tool, caughtFolder }
	local ray = workspace:Raycast(Vector3.new(goalXZ.X, sea + 200, goalXZ.Z), Vector3.new(0, -400, 0), params)
	if ray and ray.Position.Y > sea + LAND_CHECK then
		fishEvent:FireClient(player, "Cancel", "NoWater")
		return
	end

	castId += 1
	local id = castId
	state = "flying"
	castPlayer = player

	flyStart = origin
	flyGoal = Vector3.new(goalXZ.X, sea + WATER_LINE, goalXZ.Z)
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
		local wait = BITE_WAIT_MIN + math.random() * (BITE_WAIT_MAX - BITE_WAIT_MIN)
		task.delay(wait, function()
			startBite(player, id)
		end)
	end)
end

-- Drag -----------------------------------------------------------------------
local drags: { [Player]: any } = {}

local function endDrag(player: Player)
	local d = drags[player]
	if d == nil then
		return
	end
	drags[player] = nil
	if d.fish and d.fish.Parent then
		d.fish:SetAttribute("DraggedBy", nil)
	end
	for _, o in ipairs(d.objects) do
		if o and o.Parent then
			o:Destroy()
		end
	end
end

local function startDrag(player: Player, fish: any)
	if typeof(fish) ~= "Instance" or not fish:IsA("Model") then
		return
	end
	endDrag(player)
	if not fish:GetAttribute("Caught") or fish.Parent ~= caughtFolder or fish:GetAttribute("DraggedBy") then
		return
	end
	local hrp = hrpOf(player)
	local root = fish.PrimaryPart
	if hrp == nil or root == nil or (root.Position - hrp.Position).Magnitude > DRAG_RANGE then
		return
	end

	local _, yaw = root.CFrame:ToOrientation()
	local mass = math.max(root.AssemblyMass, 1)

	local goal = Instance.new("Part")
	goal.Name = "FishDragGoal"
	goal.Anchored = true
	goal.CanCollide = false
	goal.CanQuery = false
	goal.CanTouch = false
	goal.Transparency = 1
	goal.Size = Vector3.new(0.5, 0.5, 0.5)
	goal.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
	goal.Parent = caughtFolder

	local a0 = Instance.new("Attachment")
	a0.Name = "DragAttach"
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Name = "DragGoal"
	a1.Parent = goal

	local ap = Instance.new("AlignPosition")
	ap.Attachment0 = a0
	ap.Attachment1 = a1
	ap.RigidityEnabled = false
	ap.MaxForce = mass * workspace.Gravity * 6
	ap.MaxVelocity = 60
	ap.Responsiveness = 18
	ap.Parent = root

	local ao = Instance.new("AlignOrientation")
	ao.Attachment0 = a0
	ao.Attachment1 = a1
	ao.MaxTorque = mass * workspace.Gravity * 2
	ao.Responsiveness = 10
	ao.Parent = root

	fish:SetAttribute("DraggedBy", player.Name)
	drags[player] = {
		fish = fish,
		goal = goal,
		height = root.Position.Y,
		yaw = yaw,
		objects = { goal, a0, ap, ao },
	}
end

local function moveDrag(player: Player, point: any)
	local d = drags[player]
	local hrp = hrpOf(player)
	if d == nil or hrp == nil or typeof(point) ~= "Vector3" then
		return
	end
	local flat = Vector3.new(point.X - hrp.Position.X, 0, point.Z - hrp.Position.Z)
	if flat.Magnitude > DRAG_RANGE then
		flat = flat.Unit * DRAG_RANGE
	end
	local goalPos = Vector3.new(hrp.Position.X + flat.X, d.height, hrp.Position.Z + flat.Z)
	d.goal.CFrame = CFrame.new(goalPos) * CFrame.Angles(0, d.yaw, 0)
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
	elseif kind == "DragStart" then
		startDrag(player, arg)
	elseif kind == "DragMove" then
		moveDrag(player, arg)
	elseif kind == "DragEnd" then
		endDrag(player)
	end
end)

tool.Unequipped:Connect(function()
	if state == "flying" or state == "floating" or state == "biting" then
		resetRod("Unequipped")
	end
end)

Players.PlayerRemoving:Connect(function(player)
	endDrag(player)
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
		local target = seaAt(Vector3.new(bobX, bobY, bobZ)) + WATER_LINE
		local acc = SPRING_K * (target - bobY) - SPRING_D * bobVy
		bobVy += acc * dt
		bobY += bobVy * dt
		placeBobber(Vector3.new(bobX, bobY, bobZ))
		rope.Length = flyRopeGoal

	elseif state == "caught" and catchMouth then
		placeBobber(catchMouth.WorldPosition)
	end

	for player, d in pairs(drags) do
		local hrp = hrpOf(player)
		if not d.fish.Parent or not hrp or (d.fish.PrimaryPart.Position - hrp.Position).Magnitude > DRAG_LEASH then
			endDrag(player)
		end
	end
end)

-- Start in the rest pose.
setRest()
