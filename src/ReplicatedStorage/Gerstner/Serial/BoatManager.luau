--!strict
--!optimize 2

--[[
	BoatManager
	===========
	Compatibility adapter over `ReplicatedStorage.FloatingObjectGeneration.WaveFloat`.

	The buoyancy model (four hull-attached samples, slope-derived pitch/roll,
	the proportional drag term and the airborne gate) used to live here as a
	second copy of the same physics. It now lives in exactly one place,
	`WaveFloat.Solve`, so the player ship and every floating prop move with the
	same water (ROADMAP 2.4). This module keeps the old packed-result signature
	for any caller that still uses it, but returns the height as a Y-only
	vector: the caller owns X/Z (see BOAT_HANDLER.md, "Write the goal from the
	hull").

	Default height source is "ANALYTIC" (the Gerstner wave sum the ocean mesh is
	displaced with). It works on the server and on clients without
	`HeightLookup.ClientInit`. Pass "MESH" explicitly for triangle-exact
	sampling on a client that has the ocean mesh loaded.
]]

local RS = game:GetService("ReplicatedStorage")

local WaveFloat = require(RS.FloatingObjectGeneration.WaveFloat)

local BoatManager = {}

type ZONE_INFO = {
	SpeedMultiplier: number,
	AmplitudeMultiplier: number,
	PhaseMultiplier: number,
	CURRENT_ZONE: {}?,
}

--[[
	Returns `(target, orientation, clampedDepth)`.

	`target` is `Vector3.new(0, TargetY, 0)` while the hull is in the water and
	`Vector3.zero` when airborne (`WaveFloat.Solve` returned `nil`). Only its Y
	is meaningful.
]]
function BoatManager.CalculateBuoyancy(
	CenterOfMass: Vector3,
	Bottom: Vector3,
	Points: { Attachment },
	Length: number,
	Width: number,
	Height: number,
	ZoneInfo: ZONE_INFO,
	Source: string?,
	Method: string?
): (Vector3, CFrame, number)
	local targetY, orientation, depth = WaveFloat.Solve(
		Points,
		CenterOfMass.Y,
		Bottom.Y,
		Length,
		Width,
		Height,
		ZoneInfo,
		Source or "ANALYTIC",
		Method or "PRECISE",
		workspace:GetServerTimeNow()
	)

	if targetY == nil then
		return Vector3.zero, orientation, depth
	end
	return Vector3.new(0, targetY, 0), orientation, depth
end

return BoatManager
