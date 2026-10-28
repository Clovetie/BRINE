--!strict
--!native
--!optimize 2

-- // This is the parallel worker template.
-- // Depending on what WORKER_COUNT is configured to, there will be multiple instances of this script running.
-- // Each thread handles multiple ocean chunks, the total being divided equally between all workers to balance the load.
--
-- // MESSAGE CONTRACT (changed 2026-10-28 — see docs/audit/11-worker.md)
-- //   Compute(waves, Plane, EditableMesh, ChunkList, VertexList)
-- //     ChunkList  : { {Offset: Vector3, Vertices: {number}} }  — THIS worker's chunks only
-- //     VertexList : { {VertexId: number, Info: VertexKey} }    — THIS worker's vertices only
-- //   Previously the main thread sent `_CHUNKS` and the whole `VertexInfo` table to every one of
-- //   the six workers, and keyed both by Vector3, which the VM boundary stringifies — so every
-- //   worker had to `tostring(i)` and regex-parse the key back into numbers. Sending arrays of
-- //   pairs removes the parse entirely (Vector3 *values* survive the boundary; keys do not),
-- //   stops the 6x duplication of the whole chunk table, and removes a latent crash: the pattern
-- //   `(%-?%d+), ...` cannot match a non-integer coordinate, which any future CHUNK_SIZE change
-- //   would produce.
-- //   UpdateChunk(Offset, {ISLAND, ZONE}) — partial update, merged into the worker's own entry.

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local SharedTableRegistry = game:GetService('SharedTableRegistry')

local GerstnerWave = require(ReplicatedStorage.Gerstner)
local Helper = require(ReplicatedStorage.Gerstner.Helper)
local _settings = require(ReplicatedStorage.Gerstner.Settings)
local Types = require(ReplicatedStorage.Gerstner.Types)

local XZ_INCLUDE = Vector3.new(1, 0, 1)
local v3new = Vector3.new

local LERP_MAX_FRAMES = _settings.LERP_MAX_FRAMES or 30 -- // How many frames a vertex will 'lerp' for

-- // Near-shore vertices are drawn at 15% of the wave height. Multiplying by a hoisted vector
-- // replaces `Dampening += Vector3.new(0, -0.85, 0)` (which added to (1,1,1) to reach exactly
-- // this) and stops allocating a Vector3 per near-shore vertex per frame. The factor comes from
-- // Helper.SHORE_HEIGHT_FACTOR so WaveFloat can apply the same one to the height it reports.
local SHORE_DAMP = Vector3.new(1, Helper.SHORE_HEIGHT_FACTOR, 1)

-- // Height bands per crest envelope, for the colour-write gate (see the HIGH path).
local COLOR_BUCKETS = _settings.COLOR_BUCKETS or 64
local BUCKETS_PER_STUD = COLOR_BUCKETS / math.max(Helper.CREST_ENVELOPE, 1e-3)
-- // Graded colour buckets are even, so an odd sentinel cannot collide with one even where the sea
-- // is amplified past the envelope (the RoughSea zone multiplies amplitude by 2.5).
local FLAT_BUCKET = 1

local GRID_SETTINGS = _settings.GRID_SETTINGS
local Camera = workspace.Camera

local Actor: Actor = script:GetActor()
local LastPlanePosition = Vector3.zero
GerstnerWave:SET_SETTINGS(GRID_SETTINGS.Padding, GRID_SETTINGS.Width, GRID_SETTINGS.Length, GRID_SETTINGS.PaddingMultiplier, GRID_SETTINGS.UV_SCALE)

local RS = game:GetService('RunService')

-- // The worker's own copy of each chunk's tag state. `Rendering` lives ONLY here — the main
-- // thread has no idea whether a chunk was drawn last frame — so an incoming tag update must be
-- // merged into this entry, never replace it (a fresh entry resets Rendering to false, which
-- // forces every low-detail vertex in the chunk to snap to its analytic goal instead of lerping:
-- // a visible pop on every island/zone retag).
local ChunkInfo: { [Vector3]: Types.ChunkKey } = {}

Actor:BindToMessage('UpdateChunk', function(Offset, Data)
	local Entry = ChunkInfo[Offset]
	if Entry == nil then
		Entry = { Rendering = false, ISLAND = nil, ZONE = nil }
		ChunkInfo[Offset] = Entry
	end
	-- // Copy field by field: an island or zone that went away arrives as a missing key, and that
	-- // has to clear the cached one.
	Entry.ISLAND = Data.ISLAND
	Entry.ZONE = Data.ZONE
end)

local VertexTransparencyArray = SharedTableRegistry:GetSharedTable('VertexTransparency')

Actor:BindToMessage('Compute', function(waves, Plane: MeshPart, EditableMesh: EditableMesh, ChunkList, VertexList)

	-- // Rebuild this worker's own view of the grid from the arrays the main thread sent.
	-- // Both are plain arrays of pairs, so nothing needs deserialising.
	local ChunkCount = #ChunkList
	local AssignedChunks: { Vector3 } = table.create(ChunkCount)
	local _CHUNKS: { [Vector3]: { number } } = {}

	for i = 1, ChunkCount do
		local Entry = ChunkList[i]
		local Offset = Entry[1] :: Vector3
		AssignedChunks[i] = Offset
		_CHUNKS[Offset] = Entry[2] :: { number }
		if ChunkInfo[Offset] == nil then
			ChunkInfo[Offset] = { Rendering = false, ISLAND = nil, ZONE = nil }
		end
	end

	local VertexInfo: { [number]: Types.VertexKey } = {}
	local VertexCount = #VertexList
	for i = 1, VertexCount do
		local Entry = VertexList[i]
		VertexInfo[Entry[1] :: number] = Entry[2] :: Types.VertexKey
	end

	-- // Structure-of-arrays output, allocated once and reused every frame.
	-- // The old shape was `Computations[VertexId] = { position, colorId, color, uvId, uv, alpha }`
	-- // — one 6-slot table per written vertex per frame, i.e. hundreds of short-lived allocations
	-- // per worker per frame, which is where the 0.23 ms tail on the serial section came from.
	-- // Now a frame appends ids to `OutIds` and parks each attribute by vertex id; the serial pass
	-- // walks `OutIds[1..OutN]` and clears the optional slots as it consumes them, so a vertex
	-- // that stops writing a colour cannot have last frame's colour applied to it again.
	local OutIds: { number } = table.create(VertexCount)
	local OutPos: { [number]: Vector3 } = {}
	local OutColor: { [number]: Color3 } = {}
	local OutAlpha: { [number]: number } = {}
	local OutUV: { [number]: Vector2 } = {}

	-- // Write budget (Settings.PERF). Vertices are written on a staggered schedule: vertex id plus frame
	-- // number modulo N, so each frame writes about 1/N of the far vertices.
	local Frame = 0
	local REPORT_EVERY = _settings.PERF.REPORT_EVERY or 0
	local SerialMs, SerialFrames, ParallelMs = 0, 0, 0
	local PosWrites, ColorWrites, AlphaWrites, UVWrites = 0, 0, 0, 0
	local FAR_EVERY = math.max(1, math.floor(_settings.PERF.FAR_WRITE_EVERY))
	local UV_EVERY = math.max(1, math.floor(_settings.PERF.UV_WRITE_EVERY))
	-- // Distance-graded cadence: inside FAR_WRITE_DISTANCE every low-detail vertex is written every
	-- // frame (unchanged); beyond it, every Nth frame. What matters is the step per write, and out
	-- // there it is sub-pixel: at SeaState 1.0 a far vertex moves 0.151 studs per 20 Hz write, so 30
	-- // Hz (every 2nd frame) is a 0.075-stud step, which at the 400-stud near edge of the band
	-- // subtends 0.12 px and is 7% of the ~1.1-stud error the far band already carries against the
	-- // analytic surface (measured; docs/audit/10-water-look.md). 3 is safe as well (0.084 mean /
	-- // 0.16 max studs = 0.11 / 0.21 px) and is exposed as a PERF knob, not the default.
	local FAR_NEAR_DISTANCE = _settings.PERF.FAR_WRITE_DISTANCE or math.huge
	local FAR_EVERY_BEYOND = math.max(1, math.floor(_settings.PERF.FAR_WRITE_EVERY_BEYOND or FAR_EVERY))

	RS.Heartbeat:ConnectParallel(function(dt: number)
		Frame += 1
		local pStart = if REPORT_EVERY > 0 then tick() else 0
		-- // We store a bunch of variables early on that we'll be repetitively using below,
		-- // this is due to a micro-optimization with __index calls 
		-- // saving slight-moderate performance (depends on the case).
		local CameraCF = Camera.CFrame
		local distance2, farPlaneHeight2, farPlaneWidth2, rightNormal, leftNormal, topNormal, bottomNormal, frustumCFrameInverse = Helper.GetFrustumPlanes(_settings.FrustumRenderDistance, CameraCF)

		local ObjectPosition = Plane.Position
		local CameraPosition = CameraCF.Position
		local CameraXZ = CameraPosition * XZ_INCLUDE
		local t = workspace:GetServerTimeNow()

		-- // True on the frame the plane re-snapped under the camera. Everything that is a function
		-- // of world position (shore transparency, island distance) only changes then, so it is
		-- // computed once per snap instead of once per vertex per frame.
		local PlaneMoved = LastPlanePosition ~= ObjectPosition
		local ShoreEpoch = PlaneMoved or Frame == 1

		local OutN = 0
		local Active = false -- // This variable is for determining whether any of the assigned chunks are "active" (rendering)

		debug.profilebegin('Ocean update')

		for i, ChunkOffset in AssignedChunks do
			local ChunkPosition = ObjectPosition + ChunkOffset

			local ChunkData = ChunkInfo[ChunkOffset]
			local DistanceToChunk = (ChunkPosition - CameraXZ).Magnitude
			local LOWER_QUALITY = DistanceToChunk > _settings.LowRenderDistance * 2
			-- // How often this chunk's low-detail vertices are written (1 = every frame).
			local WriteEvery = if DistanceToChunk > FAR_NEAR_DISTANCE then FAR_EVERY_BEYOND else FAR_EVERY

			-- // Use frustum culling in order to
			-- // not render any chunks that aren't on the screen
			-- // leading to some moderate performance gains

			if DistanceToChunk > _settings.MaxChunkRenderDistance or Helper.IsChunkInView(ChunkPosition, CameraCF, distance2, farPlaneHeight2, farPlaneWidth2, rightNormal, leftNormal, topNormal, bottomNormal, frustumCFrameInverse) == false then
				ChunkData.Rendering = false
				continue
			end

			Active = true
			local ChunkIsland = ChunkData.ISLAND
			local IslandPosition, IslandRadius = Vector3.zero, 0

			local ChunkZone = ChunkData.ZONE
			local ZonePosition = Vector3.zero
			local ZoneParameters: Helper.ZoneParameters? = nil
			local WhirlpoolParams: Helper.ZoneParameters? = nil

			if ChunkIsland then
				IslandPosition = ChunkIsland[1]:: Vector3
				IslandRadius = ChunkIsland[2]:: number
			end
			if ChunkZone then
				ZonePosition = ChunkZone[1].Position:: Vector3
				ZoneParameters = ChunkZone[2]:: Helper.ZoneParameters
				if ZoneParameters ~= nil and ZoneParameters.Type == 'Whirlpool' then
					WhirlpoolParams = ZoneParameters
				end
			end
			-- // Once the chunk has been validated to be inside the field of view,
			-- // we loop through all of its vertices so we can calculate the next position of it

			local Vertices = _CHUNKS[ChunkOffset]
			for i, VertexId in Vertices do
				local Info = VertexInfo[VertexId]

				local PhaseMultiplier, SpeedMultiplier, AmplitudeMultiplier = 1, 1, 1
				local VertexInIslandRange = false
				local NormalizedDistanceToIsland = 1

				if ChunkIsland then
					debug.profilebegin('Island check')
					local SeaPosition = Info.Position + ObjectPosition
					SpeedMultiplier, PhaseMultiplier, AmplitudeMultiplier, VertexInIslandRange, NormalizedDistanceToIsland = Helper.GetIslandMultipliers(SeaPosition, IslandPosition, IslandRadius)

					debug.profileend()
				end
				if ChunkZone and VertexInIslandRange == false and ZoneParameters ~= nil and ZoneParameters.Type ~= 'Whirlpool' then
					debug.profilebegin('Zone check')
					local SeaPosition = Info.Position + ObjectPosition
					local VertexInRange = false

					SpeedMultiplier, PhaseMultiplier, AmplitudeMultiplier, VertexInRange = Helper.GetZoneMultipliers(SeaPosition, ZonePosition, ZoneParameters:: Helper.ZoneParameters)
					debug.profileend()
				end

				local SeaPosition = ObjectPosition + Info.Position

				-- // Shore transparency is a function of world position and the island it belongs to,
				-- // both of which only change when the plane re-snaps, so it is cached per vertex and
				-- // refreshed on the snap epoch. (With DEPTH_ENABLED = false it is the constant 1; the
				-- // cache still removes a call and a SharedTable read per vertex per frame.)
				local ShoreTransparency = Info.ShoreT
				if ShoreTransparency == nil or ShoreEpoch then
					ShoreTransparency = Helper.GetVertexTransparency(SeaPosition, VertexTransparencyArray, NormalizedDistanceToIsland)
					Info.ShoreT = ShoreTransparency
				end
				local NearShore = Helper.IsVertexNearShore(ShoreTransparency)

				-- // If the distance to the chunk is some considerable away from the camera,
				-- // we don't prioritize rendering on this chunk and instead render it 'slowly',
				-- // using Vector3.Lerp to smoothly transition the vertex from one position to the other
				-- // this allows us to call the Gerstner computation less, at the cost of some smoothness / detail
				-- // however it is unnoticeable due to the distance.
				-- // Has moderate performance gains
				if Info.QUALITY_LEVEL == 2 and ZoneParameters == nil then
					debug.profilebegin('LOW-Chunk')

					local vertex = Info.Position

					if ChunkData.Rendering == false or Info.CurrentFrame >= LERP_MAX_FRAMES or Info.Lerping == false or PlaneMoved then
						local PreviousGoal = Info.GoalPosition

						-- // If the plane's position changed relative to where we last tracked it,
						-- // we have to forcefully update the vertex, as well as
						-- // the "goal position" of the lerp, otherwise it will look very desynced

						if PlaneMoved or Info.Lerping == false or ChunkData.Rendering == false then
							local Transform = GerstnerWave.ComputeTransform(waves, SeaPosition, t, PhaseMultiplier, SpeedMultiplier, AmplitudeMultiplier)

							PreviousGoal = vertex + Transform
						end

						local Transform = GerstnerWave.ComputeTransform(waves, SeaPosition, t + (dt * LERP_MAX_FRAMES), PhaseMultiplier, SpeedMultiplier, AmplitudeMultiplier)

						Info.GoalPosition = vertex + Transform
						Info.LastPosition = PreviousGoal or EditableMesh:GetPosition(VertexId)

						Info.CurrentFrame = dt * LERP_MAX_FRAMES

						Info.Lerping = true
					end

					if Info.Lerping == true then

						-- // We proceed with normal lerping behavior

						local CurrentFrame = Info.CurrentFrame
						local CurrentLerpPosition = Helper.Lerp(Info.LastPosition, Info.GoalPosition, CurrentFrame / LERP_MAX_FRAMES)

						CurrentFrame += 1
						Info.CurrentFrame = CurrentFrame

						local Transform = CurrentLerpPosition - vertex

						-- // Nothing below this line runs on a frame this vertex is not written on:
						-- // the previous version computed the UV and the colour unconditionally, then
						-- // threw them away when the write gate skipped, AND cached them as if they
						-- // had been written — which is how a far-band vertex that crossed into the
						-- // flat-colour band on a skipped frame kept its old graded colour for good.
						if (Frame + VertexId) % WriteEvery == 0 then
							OutN += 1
							OutIds[OutN] = VertexId

							OutPos[VertexId] = if NearShore then CurrentLerpPosition * SHORE_DAMP else CurrentLerpPosition

							-- // Colour: the far field is a flat constant (cheap, and it matches what
							-- // the graded near field averages to). Both the colour and the alpha
							-- // caches are a record of what is IN THE MESH, so they may only advance
							-- // when a write actually happens.
							local VertexColor, Bucket
							if LOWER_QUALITY == true and VertexInIslandRange == false then
								VertexColor = Helper.WATERLINE_COLOR
								Bucket = FLAT_BUCKET
							else
								Bucket = math.floor(Transform.Y * BUCKETS_PER_STUD) * 2
							end

							local WriteColor = Bucket ~= Info.ColorBucket or ShoreTransparency ~= Info.AlphaTransparency
							if WriteColor then
								OutColor[VertexId] = VertexColor or Helper.GetVertexColor(Transform.Y, 0, ShoreTransparency)
								Info.ColorBucket = Bucket
							end
							if ShoreTransparency ~= Info.AlphaTransparency then
								OutAlpha[VertexId] = ShoreTransparency
								Info.AlphaTransparency = ShoreTransparency
							end

							if (Frame + VertexId) % UV_EVERY == 0 then
								OutUV[VertexId] = Helper.GetUV(Info.UV, t)
							end
						end
					end

					debug.profileend()
					continue
				end

				-- // This section is for high-detail vertices, 
				-- // where we update their position directly according to the Gerstner formula
				-- // each frame, making the waves near the camera look much smoother 

				debug.profilebegin('HIGH-Chunk')
				local vertex = Info.Position
				local VortexOffsetY = 0
				local UVOffset: Vector2? = nil

				local Transform = GerstnerWave.ComputeTransform(waves, SeaPosition, t, PhaseMultiplier, SpeedMultiplier, AmplitudeMultiplier)
				local FinalPosition = vertex + Transform

				if WhirlpoolParams ~= nil then
					local VortexOffset, VortexUV = GerstnerWave.GetVortexTransform(WhirlpoolParams, SeaPosition, Info.UV, t, ObjectPosition)
					FinalPosition += VortexOffset
					UVOffset = VortexUV
					VortexOffsetY = VortexOffset.Y
				end

				-- // We'll further reduce the amplitude if the vertex is near the shore
				if NearShore then
					FinalPosition = FinalPosition * SHORE_DAMP
				end

				Info.Lerping = false

				OutN += 1
				OutIds[OutN] = VertexId
				OutPos[VertexId] = FinalPosition

				-- // The colour is a smooth function of height, so rewriting it every frame changes
				-- // the mesh by less than one 1/64-of-envelope step (0.074 studs) while costing one
				-- // SetColor per near vertex per frame — the single largest item in the serial
				-- // section. Write only when the quantised band or the shore alpha actually moves.
				-- // Whirlpools are exempt: their darkening depends on the vortex offset, which does
				-- // not quantise to the wave height, and there are few of those vertices.
				local Bucket = if WhirlpoolParams == nil then math.floor(Transform.Y * BUCKETS_PER_STUD) * 2 else nil
				if Bucket == nil or Bucket ~= Info.ColorBucket or ShoreTransparency ~= Info.AlphaTransparency then
					OutColor[VertexId] = Helper.GetVertexColor(Transform.Y, VortexOffsetY, ShoreTransparency)
					Info.ColorBucket = Bucket
				end
				if ShoreTransparency ~= Info.AlphaTransparency then
					OutAlpha[VertexId] = ShoreTransparency
					Info.AlphaTransparency = ShoreTransparency
				end

				if (Frame + VertexId) % UV_EVERY == 0 then
					local UpdatedUV = Helper.GetUV(Info.UV, t)
					if UVOffset ~= nil then
						UpdatedUV += UVOffset -- [[Vector2]]
					end
					OutUV[VertexId] = UpdatedUV
				end
				debug.profileend()
			end

			ChunkData.Rendering = true
		end

		debug.profileend()

		-- // If we're rendering any chunks, we'll need to update their positions
		-- // to do this, we need to switch back to the serial state (task.synchronize)
		-- // then manually update each vertex and color data

		-- // TODO: Switch to bulk :SetPosition() updates once ROBLOX releases it
		if REPORT_EVERY > 0 then
			ParallelMs += (tick() - pStart) * 1000
		end
		if Active == true then
			task.synchronize()
			local serialStart = if REPORT_EVERY > 0 then tick() else 0
			debug.profilebegin('Serial Update')

			-- // We have to be sparse with what we update here, as updating too many things at once can lead to very high ms
			-- // ROBLOX batch update function plz
			local FramePos, FrameColor, FrameAlpha, FrameUV = 0, 0, 0, 0

			for i = 1, OutN do
				local VertexId = OutIds[i]

				EditableMesh:SetPosition(VertexId, OutPos[VertexId]:: Vector3)
				FramePos += 1

				local Color = OutColor[VertexId]
				local Alpha = OutAlpha[VertexId]
				if Color ~= nil or Alpha ~= nil then
					local ColorId = (VertexInfo[VertexId]:: Types.VertexKey).ColorId
					if Color ~= nil then
						EditableMesh:SetColor(ColorId, Color)
						OutColor[VertexId] = nil
						FrameColor += 1
					end
					if Alpha ~= nil then
						EditableMesh:SetColorAlpha(ColorId, Alpha)
						OutAlpha[VertexId] = nil
						FrameAlpha += 1
					end
				end

				local UV = OutUV[VertexId]
				if UV ~= nil then
					EditableMesh:SetUV((VertexInfo[VertexId]:: Types.VertexKey).UVId, UV)
					OutUV[VertexId] = nil
					FrameUV += 1
				end
			end

			if REPORT_EVERY > 0 then
				-- // Dev instrument (Settings.PERF.REPORT_EVERY): main-thread write time and the number
				-- // of API CALLS per frame, per attribute. The old counter incremented once per entry
				-- // in the output table, i.e. it counted vertices and could not see a colour write
				-- // being skipped — which is exactly the thing this pass is trying to prove.
				SerialMs += (tick() - serialStart) * 1000
				PosWrites += FramePos
				ColorWrites += FrameColor
				AlphaWrites += FrameAlpha
				UVWrites += FrameUV
				SerialFrames += 1
				if SerialFrames >= REPORT_EVERY then
					local Frames = SerialFrames
					warn(string.format(
						'OCEANPERF worker=%s serialMsPerFrame=%.3f pos=%d color=%d alpha=%d uv=%d frames=%d',
						tostring(Actor.Name), SerialMs / Frames, PosWrites / Frames, ColorWrites / Frames, AlphaWrites / Frames, UVWrites / Frames, Frames
					))
					warn(string.format('OCEANPERF2 parallelMsPerFrame=%.3f', ParallelMs / Frames))
					SerialMs, PosWrites, ColorWrites, AlphaWrites, UVWrites, SerialFrames, ParallelMs = 0, 0, 0, 0, 0, 0, 0
				end
			end
			debug.profileend()
		end

		LastPlanePosition = ObjectPosition
	end)

	if _settings.DEBUG == true then
		print('VERTEX COUNT: ', VertexCount, 'CHUNK COUNT: ', ChunkCount)
	end
end)
