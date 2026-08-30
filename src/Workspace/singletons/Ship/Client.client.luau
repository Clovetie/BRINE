--!native
--!strict
--!optimize 2

local shipReference = script:WaitForChild("Ship") :: ObjectValue
local Ship = shipReference.Value :: Model
local RunService = game:GetService("RunService")
local ZoneManager = require(game.ReplicatedStorage.Gerstner.Serial.ZoneManager)
local BoatManager = require(game.ReplicatedStorage.Gerstner.Serial.BoatManager)

local Main = Ship:WaitForChild("Main") :: BasePart
local VehicleSeat = Ship:WaitForChild("VehicleSeat") :: VehicleSeat

workspace.CurrentCamera.CameraType = Enum.CameraType.Track

local buoyancyPoints = {
	Main:WaitForChild("TopLeft") :: Attachment,
	Main:WaitForChild("TopRight") :: Attachment,
	Main:WaitForChild("BottomLeft") :: Attachment,
	Main:WaitForChild("BottomRight") :: Attachment,
}

local boatWidth = Main.Size.X
local boatLength = Main.Size.Z
local baseHeight = Main.Size.Y / 2
local maxForce = Main.AssemblyMass * workspace.Gravity * 4

local moverAttachment = Instance.new("Attachment")
moverAttachment.Name = "ShipMoverAttachment"
moverAttachment.Parent = VehicleSeat

local alignPosition = Instance.new("AlignPosition")
alignPosition.Name = "ShipBuoyancy"
alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
alignPosition.Attachment0 = moverAttachment
alignPosition.ApplyAtCenterOfMass = true
alignPosition.MaxForce = maxForce
alignPosition.MaxVelocity = 80
alignPosition.Responsiveness = 12
alignPosition.RigidityEnabled = false
alignPosition.Parent = VehicleSeat

local alignOrientation = Instance.new("AlignOrientation")
alignOrientation.Name = "ShipWaveOrientation"
alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
alignOrientation.Attachment0 = moverAttachment
alignOrientation.MaxTorque = Main.AssemblyMass * 5000
alignOrientation.MaxAngularVelocity = 8
alignOrientation.Responsiveness = 12
alignOrientation.RigidityEnabled = false
alignOrientation.Parent = VehicleSeat

local linearVelocity = Instance.new("LinearVelocity")
linearVelocity.Name = "ShipThrottle"
linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
linearVelocity.Attachment0 = moverAttachment
linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
linearVelocity.ForceLimitsEnabled = true
linearVelocity.MaxForce = Main.AssemblyMass * workspace.Gravity * 3
linearVelocity.Parent = VehicleSeat

local currentZoneInfo = {
	SpeedMultiplier = 1,
	PhaseMultiplier = 1,
	AmplitudeMultiplier = 1,
	CURRENT_ZONE = nil,
}

local function updateZoneMultipliers()
	currentZoneInfo.CURRENT_ZONE = ZoneManager:GetZoneParameters(Main.Position)
end

local zoneAccumulated = 0
local currentRotation = 0
updateZoneMultipliers()

RunService.PostSimulation:Connect(function(dt)
	zoneAccumulated += dt

	local currentZone = currentZoneInfo.CURRENT_ZONE
	if currentZone then
		if currentZone.Type ~= "Whirlpool" and currentZone.Link then
			local position = currentZone.Link.Position
			currentZoneInfo.PhaseMultiplier, currentZoneInfo.SpeedMultiplier,
				currentZoneInfo.AmplitudeMultiplier = ZoneManager:GetZoneMultipliers(
					Main.Position, position, currentZone
				)
		elseif currentZone.Type ~= "Whirlpool" and currentZone.Island then
			local islandPosition = currentZone.Island.Center.Position
			local radius = currentZone.Radius / 2
			currentZoneInfo.PhaseMultiplier, currentZoneInfo.SpeedMultiplier,
				currentZoneInfo.AmplitudeMultiplier = ZoneManager:GetIslandMultipliers(
					Main.Position, islandPosition, radius
				)
		end
	end

	if VehicleSeat.Steer == 1 then
		currentRotation -= math.rad(0.5)
	elseif VehicleSeat.Steer == -1 then
		currentRotation += math.rad(0.5)
	end

	linearVelocity.VectorVelocity = if VehicleSeat.Throttle == 1
		then VehicleSeat.CFrame.LookVector * 30
		else Vector3.zero

	local height, orientation, depth = BoatManager.CalculateBuoyancy(
		Main.CenterOfMass,
		Main.Center.WorldPosition,
		buoyancyPoints,
		boatLength,
		boatWidth,
		baseHeight,
		currentZoneInfo
	)

	if height ~= Vector3.zero then
		alignPosition.Enabled = true
		alignPosition.MaxForce = maxForce * (1 + (depth / 10))
		alignPosition.Position = height
	else
		alignPosition.Enabled = false
	end

	alignOrientation.CFrame = CFrame.fromEulerAnglesXYZ(0, currentRotation, 0) * orientation

	if zoneAccumulated >= 3 then
		zoneAccumulated = 0
		updateZoneMultipliers()
	end
end)

ZoneManager.ZoneUpdated:Connect(updateZoneMultipliers)
