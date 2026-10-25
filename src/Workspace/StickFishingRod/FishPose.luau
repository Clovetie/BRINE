--!strict
-- Pose math shared by the fishing server (real catch) and client (viewport).
-- A fish's `BobberPos` attachment is its bite point. `Target` returns the pivot
-- CFrame that puts that point exactly on `point`, with the fish's +Z (mouth side)
-- pointing along `facing` (horizontal-ish unit vector from the body toward the bobber).

local FishPose = {}

function FishPose.Target(model: Model, point: Vector3, facing: Vector3): CFrame?
	local primary = model.PrimaryPart
	local mouth = model:FindFirstChild("BobberPos", true)
	if primary == nil or mouth == nil or not mouth:IsA("Attachment") then
		return nil
	end

	local rot = CFrame.lookAt(Vector3.zero, -facing)
	-- Mouth offset in the primary part's own frame (before we re-orient it).
	local m = primary.CFrame:PointToObjectSpace(mouth.WorldPosition)
	local primaryGoal = CFrame.new(point - rot:VectorToWorldSpace(m)) * rot

	-- Convert primary goal to a pivot goal, since PivotTo moves the model pivot.
	local pivotFromPrimary = model:GetPivot():ToObjectSpace(primary.CFrame)
	return primaryGoal * pivotFromPrimary:Inverse()
end

return FishPose
