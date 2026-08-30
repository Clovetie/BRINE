--!strict
-- Shared configuration for the hand-holding system.
-- Both the server and the client require this so their numbers always match.

return {
	-- Maximum distance (studs) between two HumanoidRootParts for a valid
	-- offer, acceptance, or active hand-holding connection.
	MAX_DISTANCE = 8,

	-- How far (in degrees) from the player's facing direction the client is
	-- allowed to look for a target in front of them.
	MAX_LOOK_ANGLE_DEGREES = 110,

	-- How long (seconds) an unnotched offer may live before it expires.
	OFFER_TIMEOUT = 3,

	-- How long (seconds) the IK Weight takes to blend in or out.
	IK_FADE_TIME = 0.25,

	-- IKControl.SmoothTime. Larger = softer/slower reaching; smaller = snappier.
	IK_SMOOTH_TIME = 0.12,

	-- How often (seconds) the server re-validates offers and drops stale ones.
	VALIDATION_INTERVAL = 0.5,
}
