-- FishingConfig: every tuning value for the fishing rod in one place.
-- Change numbers here only. The server (FishingServer) and the viewport
-- (FishingClient) both read this table, so a change applies to both.

local Config = {}

-- Casting ----------------------------------------------------------------------
Config.Cast = {
	Range = 90,          -- max horizontal cast distance (studs)
	MinDistance = 8,     -- closer than this does nothing
	LandCheck = 4,       -- ground this far above the sea means "not water"
	ClientTimeout = 15,  -- seconds before the rod frees itself if the server never answers
}

-- Bite -------------------------------------------------------------------------
Config.Bite = {
	WaitMin = 3.5,       -- seconds the bobber floats before a bite (minimum)
	WaitMax = 7,         -- seconds the bobber floats before a bite (maximum)
	Approach = 2.2,      -- seconds for the fish to reach the bobber
	HookWindow = 3.0,    -- seconds after the bait is taken to click (one click for now)
	ScaleMin = 0.8,      -- random fish scale, low end
	ScaleMax = 1.3,      -- random fish scale, high end
	WaterLine = 0.1,     -- bobber centre rides this far above the sea surface
	SpringK = 25,        -- bobber water spring stiffness
	SpringD = 10,        -- bobber water damping (critical is about 2 * sqrt(K))
	FallbackSea = 24.98, -- sea height used if the wave query fails
}

-- Catch: the fish is reeled up to the player, then thrown behind them -----------
Config.Catch = {
	ReelTime = 1.1,      -- seconds to pull the fish up to the player
	ReelArc = 6,         -- studs the reel path lifts above a straight line
	HoldFront = 1.5,     -- hold point: studs in front of the player
	HoldHeight = 4,      -- hold point: studs above the player's root (above the head)
	ThrowBack = 24,      -- studs/s thrown behind the player on release
	ThrowUp = 26,        -- studs/s upward on release (clears the head)
}

-- Floating: a caught fish that lands on the water rides the surface ------------
Config.Float = {
	Depth = 0.5,         -- fish centre rides this far below the surface
	EnterBand = 1.0,     -- a falling fish lands on the water within this height
}

-- Grab: Roblox physics constraints (AlignPosition / AlignOrientation) -----------
Config.Grab = {
	Range = 22,          -- how far a caught fish may be from the player to grab it
	Leash = 40,          -- auto-release beyond this distance
	SendInterval = 0.05, -- seconds between drag position updates from the client
	Responsiveness = 18, -- AlignPosition responsiveness
	ForceMultiplier = 6, -- AlignPosition max force, in multiples of the fish's weight
}

-- Viewport (the FishingRodUI picture) -------------------------------------------
Config.Viewport = {
	ContactDistance = 0.6,   -- bite point within this distance of the bobber counts as contact
	WiggleSpeed = 8,         -- wriggle speed, radians per second (about 1.3 swings a second)
	WiggleYaw = 30,          -- wriggle swing either side, in degrees, about the bite point
	HideAfterCatch = 2.5,    -- seconds the viewport stays up after a catch
	HideAfterCancel = 1.5,   -- seconds the message stays up after a cancelled cast
	SeaY = 24.98,            -- water height used to aim casts that miss the water mesh
	Facing = Vector3.new(-1, 0.15, -0.35).Unit, -- the fish's approach direction in the viewport
}

-- FloatingGui: the rod UI floats in front of the camera -------------------------
-- These are passed straight to Workspace.FloatingGui (FloatingGui.new options):
--   Distance  studs between the camera and the floating UI
--   Speed     follow speed, 0 to 1
--   Angle     rotation in degrees
--   Offset    shift as a fraction of the screen (Vector2: X right, Y down)
Config.Gui = {
	Distance = 0.2,
	Speed = 0.9,
	Angle = 0,
	Offset = Vector2.new(0, 0),
}

return Config
