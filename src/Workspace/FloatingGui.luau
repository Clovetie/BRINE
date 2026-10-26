local FloatingGui = {}
FloatingGui.__index = FloatingGui

local RunService = game:GetService('RunService')
local Players = game:GetService('Players')

local Player = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local Created = {}
local DefaultOptions = {
	Distance = 0,
	Angle = 0,
	Speed = 0.9,
	Offset = Vector2.new(0, 0)
}

local function CreatePart(): Part
	local Part = Instance.new("Part")
	Part.Size = Vector3.new(20, 10, 0.5)
	Part.CanCollide = false
	Part.CanQuery = false
	Part.CanTouch = false
	Part.CastShadow = false
	Part.Massless = true
	Part.Transparency = 1
	Part.Anchored = true
	Part.Name = 'FloatingGuiAdornee'
	Part.Parent = workspace

	return Part
end

local function CreateSurfaceGui(Adornee): SurfaceGui
	local SurfaceGui = Instance.new("SurfaceGui")
	SurfaceGui.Adornee = Adornee --connect it to the frame we just made
	SurfaceGui.Face = Enum.NormalId.Front --set its side to Back
	SurfaceGui.PixelsPerStud = 512 --set the PPS, can be anything but i recomment 512
	SurfaceGui.ClipsDescendants = false
	SurfaceGui.AlwaysOnTop = true --make it always visible
	SurfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud

	return SurfaceGui
end

local function Log(Message: string, FunctionName, ...)
	local HasTable = false
	
	for i, v in pairs({...}) do
		if typeof(v) == 'table' then
			HasTable = true
		end
	end
	
	if HasTable then
		warn(`{script.Name}{FunctionName}(`, ..., `) - {Message}`)
	else
		warn(`{script.Name}{FunctionName}({... or ''}) - {Message}`)
	end
end

local function OnRenderStepped()
	for i, Gui in ipairs(Created) do
		local Exists = Gui.SurfaceGui.Parent and Gui.ScreenGui.Parent and Gui.Part.Parent and true or false
		
		if not Exists then
			Gui:Remove()
			
			return
		end
		
		if not Gui.SurfaceGui.Enabled then continue end

		local Part = Gui.Part

		local Options = Gui.Options
		local Distance = Options.Distance
		local Angle = Options.Angle
		local Speed = Options.Speed
		local Offset = Options.Offset

		local ForwardOffset = 1

		local Height = math.tan(math.rad(Camera.FieldOfView/2)) * 2 * (ForwardOffset + Part.Size.Z / 2)
		local Width = (Camera.ViewportSize.X / Camera.ViewportSize.Y) * Height
		Part.Size = Vector3.new(Width, Height, Part.Size.Z)

		local XOffset = Width * Offset.X
		local YOffset = Height * Offset.Y
		local Lerp = math.clamp(0.9 + Speed / 10, 0, 1)

		local CF = (Camera.CFrame + Camera.CFrame.LookVector * (ForwardOffset + Distance + Part.Size.Z) + Camera.CFrame.RightVector * XOffset + Camera.CFrame.UpVector * YOffset) * CFrame.Angles(0, math.rad(180), 0)
		Part.CFrame = Part.CFrame:Lerp(CF, Lerp) * CFrame.Angles(0, math.rad(Angle), 0)
	end
end

local function SetOptions(FloatingGui, Options: {}, FunctionName)
	local self = FloatingGui

	for OptionName, Value in pairs(Options) do
		local DefaultValue = DefaultOptions[OptionName]
		local DefaultType = typeof(DefaultOptions[OptionName])

		if not DefaultValue then Log(`{OptionName} is not a valid option.`, FunctionName, Options) continue end

		if typeof(Value) ~= DefaultType then 
			self.Options[OptionName] = self.Options[OptionName] or DefaultValue

			Log(`{OptionName} should be of type: '{DefaultType}'`, FunctionName, Options) 
			continue 
		end

		self.Options[OptionName] = Value
	end
	
	for OptionName, Value in pairs(DefaultOptions) do
		if not self.Options[OptionName] then
			self.Options[OptionName] = Value
		end
	end
end

function FloatingGui.new(ScreenGui: ScreenGui, Options: {})
	if not ScreenGui or ScreenGui.ClassName ~= 'ScreenGui' then Log(`Provide a ScreenGui.`, '.new', ScreenGui, Options) end
	
	local self = setmetatable({}, FloatingGui)
	self.ScreenGui = ScreenGui
	self.Options = {}
	self.Part = CreatePart()
	self.SurfaceGui = CreateSurfaceGui(self.Part)
	self.ScreenGuiParent = ScreenGui.Parent
	self.Removed = false
	
	SetOptions(self, Options or {}, '.new')
	
	ScreenGui.Parent = game.ReplicatedFirst
	
	for i, Child in pairs(ScreenGui:GetChildren()) do
		Child.Parent = self.SurfaceGui
	end
	
	self.SurfaceGui.Name = ScreenGui.Name
	self.SurfaceGui.Parent = self.ScreenGuiParent
	
	table.insert(Created, self)
	
	return self
end

function FloatingGui:Change(Options)
	if not Options or typeof(Options) ~= 'table' then Log(`Provide a table.`, ':Change', Options) return end
	
	if self.Removed then Log(`You can't change a FloatingGui after removing it.`, ':Change', Options) return end
	
	SetOptions(self, Options, ':Change')
end

function FloatingGui:Remove()
	if self.Removed then Log(`This FloatingGui has already been removed.`, ':Remove') return end
	self.Removed = true

	table.remove(Created, table.find(Created, self))

	for i, Child in pairs(self.SurfaceGui:GetChildren()) do
		Child.Parent = self.ScreenGui
	end
	
	self.Part:Destroy()
	self.SurfaceGui:Destroy()
	
	if self.ScreenGui.Parent ~= nil then
		self.ScreenGui.Parent = self.ScreenGuiParent
	end
end

function FloatingGui:Enable(Boolean: boolean | nil)
	if Boolean and typeof(Boolean) ~= 'boolean' then Log(`Provide a boolean or nothing.`, ':Enable', Boolean) return end
	
	local Enabled = Boolean == nil and true or Boolean
	
	if self.Removed then Log(`You can't {Enabled and 'enable' or 'disable'} a FloatingGui after removing it.`, ':Enable', Boolean) return end
	
	self.SurfaceGui.Enabled = Boolean
end

--RunService:BindToRenderStep('Camera', Enum.RenderPriority.Camera.Value + 1, OnRenderStepped)
RunService.RenderStepped:Connect(OnRenderStepped)

return FloatingGui