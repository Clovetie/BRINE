local GerstnerWave = require(script.Parent)

-- // This is our setup for the Gerstner Waves,
-- // We use a table to store multiple waves
-- // The more waves you can use, the more detail / realism you will get to actual ocean waves
-- // However, this comes at the cost of performance

--[[ 
	// Properties:
		 	1. Direction: a Vector3 value which stores the waves direction in the XZ axis
				2. WaveLength: The distance between each peak or trough. The lower the value, the more peaks, the higher, the less
				3. Amplitude: How 'high' the waves go
				4. Gravity
	
	// DEBUG: Boolean indicating whether debug messages will be shown in console.
	
  	// Grid Settings:
		Width: Width of the plane mesh (X)
		Length: Length of the plane mesh (Z)
		Padding: Distance between each vertex
		PaddingMultiplier: Multiplier for the padding. Used for tiling the material of the plane
		CHUNK_SIZE: The size of each 'chunk' for the ocean.
		PLANE_OFFSET: A Vector3 offset for the plane mesh, used if you want the plane to be on a different Y level, instead of y=0
					  as the origin.
		
	// WORKER_COUNT: How many threads or workers to use for the ocean. Should be balanced for the amount of chunks the ocean has.
	
	// FrustumRenderDistance: How far the camera plane extends for Frustum Culling. For example, any chunks past 'FrustumRenderDistance'
							  will be considered 'not in view'.
	
	// LowRenderDistance: 	  Any chunks past this distance will be considered a 'low quality' chunk, and will use lerping in order to
						  	  keep calculations at a minimum.
						  	  
	
	// MaxChunkRenderDistance: Any chunks past this distance will not have any computations done on them.
	
	// Subdivisions: Takes an array in the format of
					 [int] = Distance,
					 Where distance is just the 'range' in which subdivision will occur. This allows you to generate different
					 LOD levels depending on the ocean planes size and have more detail near the 'center' of the mesh (near the camera)
	
	// ISLAND_SPEED_MULTIPLIER / ISLAND_PHASE_MULTIPLIER: Simple multipliers for the phase and speed properties of Gerstner waves,
														  which are applied when a vertex is near an island.
														  
	// Wave Colors:
		CREST: The color of the top of a wave. Usually a lighter color compared to the trough.
		TROUGH: The color of the bottom of a wave. Usually a darker color.
		VORTEX: The intended color for a water vortex / whirlpool in the ocean.
		SHORE: The color of the ocean near shores of islands. ([DEPTH_ENABLED = TRUE] REQUIRED)
		
	// UV_SCROLL_SPEED: The speed of the texture scrolling on the ocean.
	// UV_SCROLL_DIRECTION: The direction for the texture scrolling on the ocean.
	
	// DEPTH_ENABLED: A boolean indicating whether depth coloring is active, allowing the ocean handler to automatically detect shores of islands
		and set their color to the "SHORE" color, as well as giving them some transparency.
	// DEPTH_RAY_LENGTH: The length for a raycast for depth, performed on each vertex of the mesh.
	// DEPTH_RAY_OFFSET: The offset position for depth raycasts.
	// SHORE_TRANSPARENCY: The transparency for vertices on shallow water
	
	// WHITECAP_HEIGHT: Determines the height at which ocean vertices will begin to turn white to simulate a foam effect.]]

-- // https://www.desmos.com/calculator/uvdibm39mm

local Seed = script.Seed.Value
if Seed == 0 then
	Seed = math.random(-100000, 100000)
	print(`SEED: {Seed}`)
	script.Seed.Value = Seed
end
local R = Random.new(Seed)

-- // This is basically a function to generate random waves
local WLMultiplier, AmplitudeMultiplier = 1.14, 0.86
local function BrownianMotionWaves(Amount: number): { GerstnerWave.WaveInfo }
	local Results = {}
	local WaveLength, Amplitude = 40, 0.3

	local PrimaryDirectionUnit = workspace.GlobalWind.Unit

	for i = 1, Amount do
		if Amplitude <= 0.05 then
			warn("Stopped at " .. i .. " as amplitude reached threshold (0.025)")
			break
		end
		local RandomDirectionUnit = R:NextUnitVector()
		local Direction = i == 1 and PrimaryDirectionUnit or (RandomDirectionUnit + PrimaryDirectionUnit).Unit

		local WaveInfo = GerstnerWave.new(Direction, WaveLength, Amplitude)
		table.insert(Results, WaveInfo)

		WaveLength *= WLMultiplier
		Amplitude *= AmplitudeMultiplier
	end
	print("Successfully generated " .. #Results .. " waves!")
	return Results
end

local Settings = {
	-- // Debug messages print in Studio only; live servers and clients stay quiet.
	DEBUG = game:GetService('RunService'):IsStudio(),
	GRID_SETTINGS = {
		CHUNK_SIZE = 100,
		Padding = 48,
		PLANE_OFFSET = Vector3.new(0, 25, 0),
		Width = 40,
		Length = 40,

		PaddingMultiplier = 1,
		UV_SCALE = 2,

		-- // Secondary ocean tiles, 0-8 (ROADMAP 2.3). 8 = full ring (default).
		SECONDARY_PLANES = 8,
	},

	WORKER_COUNT = 6,
	FrustumRenderDistance = 900,
	LowRenderDistance = 200,
	-- // Mesh detail: vertices further than this from the mesh centre use the lerped (LOD) path.
	-- // Lerp error at this range is well under a stud for the sea's wave periods (about 4 to 6 s).
	MeshDetailDistance = 120,
	MaxChunkRenderDistance = 800,

	Subdivisions = {
		[1] = 400,
		[2] = 200,
	},

	--Waves = BrownianMotionWaves(6);
	-- // Four waves from different headings, so the sea is not one rolling set. Wavelengths stay
	-- // at 25 studs or more (the mesh grid is 48 studs). Steepness sums to 0.69; the old set summed
	-- // to 1.35, past the point where Gerstner waves loop. Gerstner.SeaStateAt scales these into
	-- // calm and rough patches.
	Waves = {
		GerstnerWave.new(Vector3.new(0.92, 0, 0.38).Unit, 58, 0.26),
		GerstnerWave.new(Vector3.new(-0.35, 0, 0.94).Unit, 41, 0.20),
		GerstnerWave.new(Vector3.new(0.71, 0, -0.71).Unit, 30, 0.14),
		GerstnerWave.new(Vector3.new(-0.96, 0, -0.27).Unit, 25, 0.09),
	},

	ISLAND_SPEED_MULTIPLIER = 1.1,
	ISLAND_PHASE_MULTIPLIER = 1,

	WAVE_COLORS = {
		CREST = Color3.fromRGB(77, 166, 156),
		TROUGH = Color3.fromRGB(46, 89, 118),
		VORTEX = Color3.fromRGB(18, 28, 33),
		SHORE = Color3.fromRGB(60, 186, 171),
	},
	UV_SCROLL_SPEED = 1 / 12,
	UV_SCROLL_DIRECTION = Vector2.new(1, 1),

	DEPTH_ENABLED = false, -- // Note: Check known issues #4 in thread linked below
	DEPTH_RAY_LENGTH = Vector3.new(0, -15, 0),
	DEPTH_RAY_OFFSET = Vector3.new(0, 5, 0),

	WHITECAP_HEIGHT = 6,
	SHORE_TRANSPARENCY = 0.2,

	-- // Render write budget. Every visible vertex is still computed each frame on the workers,
	-- // but only a share of them is written to the EditableMesh, which runs serially on the main
	-- // thread. Writes are staggered by vertex id so the cost is spread over frames. 1 = write
	-- // every frame (the original behaviour, used for A/B tests).
	PERF = {
		-- // FAR_WRITE_EVERY = 1: far vertices are written EVERY frame. The budget
		-- // was 3 and it quantised the far field to 20 Hz, which is the distant
		-- // stepping/shimmer: at SeaState 1.0 a far vertex moved 0.151 studs per
		-- // write (p99 0.253) at 3, against 0.050 (p99 0.085) at 1. Measured cost
		-- // of writing every frame: serial 0.149 -> 0.226 ms per worker per frame,
		-- // i.e. about +0.46 ms/frame across six workers, over two sessions.
		-- // See docs/audit/02-waves-findings.md.
		FAR_WRITE_EVERY = 1, -- // far (low-detail) vertices: position and colour written every N frames
		-- // The UV scroll is a texture scroll, not geometry, so a low cadence is invisible.
		-- // UV_WRITE_EVERY = 6: a UV write costs about 7x a position write (5.7 us vs 0.82 us, one
		-- // session each - a lead, not a result; docs/audit/03-perf.md). The scroll is a pure texture
		-- // scroll at 1/12 UV per second, so at 60 fps a 6-frame cadence steps it 0.0083 UV units,
		-- // about 0.2 studs of texture travel per write: not resolvable at any view distance.
		UV_WRITE_EVERY = 6, -- // UV scroll written every N frames (the scroll is slow)

		-- // Distance-graded position/colour cadence (see ParallelWorker). Inside FAR_WRITE_DISTANCE
		-- // a low-detail vertex is written every frame; beyond it, every FAR_WRITE_EVERY_BEYOND'th.
		-- // 400 studs is the same edge the far field already uses for its flat colour
		-- // (LowRenderDistance * 2), so the two LOD shortcuts change over together.
		FAR_WRITE_DISTANCE = 400,
		FAR_WRITE_EVERY_BEYOND = 2,
		REPORT_EVERY = 0, -- // dev only: warn a write-time summary every N frames per worker (0 = off)
	},

	-- // DEBUG
	-- // Known issues thread: https://devforum.roblox.com/t/client-beta-in-experience-mesh-image-apis-now-available-in-published-experiences/3267293
}

-- // Hand the grid to Gerstner so its whirlpool UV math has real values.
-- // Gerstner's own defaults are Padding = 0, which divides by zero in GetUVCoordinates.
-- // This lives here, not in Gerstner's init, because Settings requires Gerstner (no cycle).
local GRID = Settings.GRID_SETTINGS
GerstnerWave:SET_SETTINGS(GRID.Padding, GRID.Width, GRID.Length, GRID.PaddingMultiplier, GRID.UV_SCALE)

return Settings
