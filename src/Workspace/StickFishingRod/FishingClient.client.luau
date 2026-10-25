-- FishingClient: casting input, the FishingRodUI viewport, and dragging caught fish.
-- The viewport has its own client-side Camera; nothing here changes the world.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local tool = script.Parent
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local FishPose = require(tool:WaitForChild("FishPose"))
local remotes = tool:WaitForChild("FishingRemotes")
local fishEvent = remotes:WaitForChild("FishEvent")
local action = remotes:WaitForChild("Action")

local SEA_Y = 24.98
local DRAG_SEND_INTERVAL = 0.05
local HIDE_AFTER_CATCH = 2.5
local HIDE_AFTER_CANCEL = 1.5
local CONTACT_DISTANCE = 0.6
local FACING = Vector3.new(-1, 0.15, -0.35).Unit

local CAST_TIMEOUT = 15

local CANCEL_TEXT = {
	NoWater = "Nothing in the water.",
	NoFish = "Nothing here.",
	NoCharacter = "Cast failed.",
	BadFish = "Cast failed.",
	Busy = "Already fishing.",
	TooClose = "Cast further out.",
	Unequipped = "",
}

-- UI -------------------------------------------------------------------------
local gui = tool:WaitForChild("FishingRodUI")
gui.ResetOnSpawn = false
gui.Enabled = false
gui.Parent = playerGui

local background = gui:WaitForChild("Background")
local reactive = background:WaitForChild("FishingReactive")
local viewport = background:WaitForChild("FishViewport")

viewport.Ambient = Color3.fromRGB(150, 160, 180)
viewport.LightColor = Color3.fromRGB(255, 255, 255)
viewport.LightDirection = Vector3.new(-0.4, -1, -0.3)

-- Viewport-only camera (client-sided, never replicated).
local camera = Instance.new("Camera")
camera.Name = "FishCamera"
camera.FieldOfView = 55
camera.CFrame = CFrame.new(Vector3.new(0, 2.5, 13), Vector3.new(0, -0.5, 0))
camera.Parent = viewport
viewport.CurrentCamera = camera

local scene = Instance.new("Model")
scene.Name = "FishScene"
scene.Parent = viewport

local sceneActive = false
local bobberClone: BasePart? = nil
local fish: Model? = nil
local fishName = ""
local startPivot: CFrame? = nil
local endPivot: CFrame? = nil
local contacted = false
local approachTween: Tween? = nil
local approachAlpha = Instance.new("NumberValue")
local hideToken = 0

approachAlpha.Changed:Connect(function(value)
	if fish and startPivot and endPivot then
		fish:PivotTo(startPivot:Lerp(endPivot, value))
	end
end)

local function makePart(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Transparency = transparency
	p.Parent = scene
	return p
end

local function clearScene()
	scene:ClearAllChildren()
	bobberClone = nil
	fish = nil
	startPivot = nil
	endPivot = nil
	contacted = false
	if approachTween then
		approachTween:Cancel()
		approachTween = nil
	end
	approachAlpha.Value = 0
end

local function buildScene()
	clearScene()
	-- Water: a translucent surface with a deeper blue tint below it.
	makePart("Water", Vector3.new(60, 0.2, 60), CFrame.new(0, 0, 0),
		Color3.fromRGB(40, 130, 185), Enum.Material.Glass, 0.45)
	makePart("WaterDepth", Vector3.new(60, 24, 60), CFrame.new(0, -12.1, 0),
		Color3.fromRGB(15, 70, 120), Enum.Material.SmoothPlastic, 0.6)

	local source = tool:FindFirstChild("Rod") and tool.Rod:FindFirstChild("Bobber")
	if source and source:IsA("BasePart") then
		local b = source:Clone()
		for _, child in ipairs(b:GetChildren()) do
			if child:IsA("Constraint") or child:IsA("WeldConstraint") or child:IsA("VectorForce") then
				child:Destroy()
			end
		end
		b.Anchored = true
		b.CanCollide = false
		b.CanQuery = false
		b.CanTouch = false
		b.AssemblyLinearVelocity = Vector3.zero
		b.CFrame = CFrame.new(0, 0.1, 0) -- sits on the water surface, not moved again
		b.Parent = scene
		bobberClone = b
	end
	sceneActive = true
end

local function hideUi()
	hideToken += 1
	sceneActive = false
	gui.Enabled = false
	clearScene()
end

local function showUi(text: string)
	hideToken += 1
	gui.Enabled = true
	buildScene()
	reactive.Text = text
end

-- Viewport bite -------------------------------------------------------------
local biteSeen = false  -- set by onBite; read by the cast timeout

local function onBite(name: string, scale: number, approach: number)
	biteSeen = true
	if not sceneActive then
		showUi("Catching...")
	end
	buildScene()
	reactive.Text = "Catching..."
	fishName = name

	local previewFolder = ReplicatedStorage:WaitForChild("FishingPreviews", 5)
	local pv = previewFolder and previewFolder:WaitForChild(tostring(player.UserId), 5)
	if not pv or not bobberClone then
		return
	end

	local model = pv:Clone() :: Model
	model.Parent = scene
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
		end
	end
	fish = model

	local bp = bobberClone:FindFirstChild("BobberPoint") :: Attachment
	local target = FishPose.Target(model, bp.WorldPosition, FACING)
	if target == nil then
		return
	end
	endPivot = target
	startPivot = CFrame.new(-FACING * 6 + Vector3.new(0, -3, 0)) * target
	model:PivotTo(startPivot)

	approachAlpha.Value = 0
	approachTween = TweenService:Create(approachAlpha,
		TweenInfo.new(approach, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = 1 })
	approachTween:Play()
end

local function onCaught(name: string)
	if not sceneActive then
		return
	end
	reactive.Text = name .. " Caught!"
	local token = hideToken
	task.delay(HIDE_AFTER_CATCH, function()
		if token == hideToken then
			hideUi()
		end
	end)
end

local function onCancel(reason: string)
	local text = CANCEL_TEXT[reason] or "Cast failed."
	if text == "" then
		hideUi()
		return
	end
	reactive.Text = text
	local token = hideToken
	task.delay(HIDE_AFTER_CANCEL, function()
		if token == hideToken then
			hideUi()
		end
	end)
end

fishEvent.OnClientEvent:Connect(function(kind: string, a: any, b: any, c: any)
	if kind == "Bite" then
		onBite(a, b, c)
	elseif kind == "Caught" then
		onCaught(a)
	elseif kind == "Cancel" then
		onCancel(a)
	end
end)

RunService.RenderStepped:Connect(function()
	if not sceneActive then
		return
	end
	-- The viewport bobber is static: no bob, no sway (it is set once in buildScene).
	if fish and bobberClone and not contacted and approachAlpha.Value >= 0.999 then
		local mouth = fish:FindFirstChild("BobberPos", true) :: Attachment
		local bp = bobberClone:FindFirstChild("BobberPoint") :: Attachment
		if mouth and bp and (mouth.WorldPosition - bp.WorldPosition).Magnitude < CONTACT_DISTANCE then
			contacted = true
			reactive.Text = fishName .. " Bit bait!"
		end
	end
end)

-- Input: cast and drag ----------------------------------------------------------
local function mouseRay(): Ray
	local loc = UserInputService:GetMouseLocation()
	return workspace.CurrentCamera:ViewportPointToRay(loc.X, loc.Y)
end

local function rayParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character :: Instance, tool }
	return params
end

local function fishUnderCursor(): Model?
	local ray = mouseRay()
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 500, rayParams())
	if hit == nil then
		return nil
	end
	local model = hit.Instance:FindFirstAncestorOfClass("Model")
	if model and model:GetAttribute("Caught") and not model:GetAttribute("DraggedBy") then
		return model
	end
	return nil
end

local function castTarget(): Vector3
	local ray = mouseRay()
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 400, rayParams())
	if hit then
		return hit.Position
	end
	if ray.Direction.Y < -0.01 then
		local t = (SEA_Y - ray.Origin.Y) / ray.Direction.Y
		if t > 0 then
			return ray.Origin + ray.Direction * t
		end
	end
	return ray.Origin + ray.Direction * 80
end

local dragFish: Model? = nil
local dragHeight = 0
local lastDragSend = 0

local castSerial = 0

tool.Activated:Connect(function()
	if dragFish or sceneActive then
		return
	end
	if fishUnderCursor() then
		return
	end
	showUi("Catching...")
	castSerial += 1
	biteSeen = false
	local mine = castSerial
	action:FireServer("Cast", castTarget())
	-- Safety net: if the server never answers, free the rod instead of waiting forever.
	task.delay(CAST_TIMEOUT, function()
		if mine == castSerial and not biteSeen and sceneActive then
			hideUi()
		end
	end)
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end
	local fish = fishUnderCursor()
	if fish and fish.PrimaryPart then
		dragFish = fish
		dragHeight = fish.PrimaryPart.Position.Y
		action:FireServer("DragStart", fish)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 and dragFish then
		dragFish = nil
		action:FireServer("DragEnd")
	end
end)

RunService.RenderStepped:Connect(function()
	if dragFish == nil then
		return
	end
	if dragFish.Parent == nil then
		dragFish = nil
		return
	end
	local now = os.clock()
	if now - lastDragSend < DRAG_SEND_INTERVAL then
		return
	end
	local ray = mouseRay()
	if math.abs(ray.Direction.Y) < 0.001 then
		return
	end
	local t = (dragHeight - ray.Origin.Y) / ray.Direction.Y
	if t <= 0 then
		return
	end
	lastDragSend = now
	action:FireServer("DragMove", ray.Origin + ray.Direction * t)
end)
