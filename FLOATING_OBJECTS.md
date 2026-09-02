# Floating Object Generation

Streams **unanchored** floating structures and debris into the BRINE ocean
world. Like the island generator, it does **not** author geometry — floating
objects are handmade `Model`s (or single `BasePart`s) under
`ServerStorage.FloatingObjects`. The generator discovers those templates,
reads their **size tag**, caches deterministic records around moving players,
and only clones/renders a record while a player can actually see it.

The hard render cap is `FloatingObjectConfig.Streaming.MaxRenderedObjects`
(default `500` unanchored objects in `workspace` at once). When the cap is
exceeded the generator evicts the **oldest** rendered records first, and
prefers records with **no player nearby** (`Despawn.CullNearPlayerDistance`).
The cached record count can keep growing as players travel, but real physics
instances stay bounded.

## Template folder (`ServerStorage.FloatingObjects`)

- Folders may nest to any depth; recursion does **not** descend into a
  `Model`, so sub-models (a ship's mast, a raft's planks) are components,
  not templates.
- Each template carries **one size tag** via `CollectionService`:
  `Small`, `Medium`, `Large`, or `Debris`. If several tags are present, the
  first match in `FloatingObjectConfig.ClassTags` order wins. Untagged
  templates are skipped with a warning.
- Per-class tuning (spawn weight, per-cell counts, spacing, simulation
  distance, default float ratio) lives in `FloatingObjectConfig.Classes`.
- Optional template overrides (set on the template instance):
  - `FloatRatio` number attribute — how sunk the object rides: the mover
    point is held `bboxHeight * (FloatRatio - 0.5)` above the waterline, so
    `0.5` floats at the middle of the bounding box and `0.8` floats low
    (hull nearly awash).
  - `SimDistance` number attribute — per-object LOD distance override.
  - A `PrimaryPart` is recommended; otherwise the largest part is used.

## Runtime hierarchy

```
workspace
└── _FloatingObjects            (Folder, created by the generator)
    ├── Crate (Model)           tagged "FloatingObject", unanchored while buoyant
    ├── Wreck (Model)           anchored while frozen, cached by Destroy when unseen
    └── ...
```

Every rendered clone is tagged `"FloatingObject"` (deliberately **not**
`"Island"` — `ZoneManager` must never index these). Children of the container
always equal `GetStats().RenderedObjects`.

## Three-tier LOD (the "streaming" optimization)

Each rendered record is in exactly one of three states:

1. **Buoyant** — unanchored, driven by `AlignPosition` + `AlignOrientation`
   against a wave sample taken at real `Attachment`s on the hull (see "How a
   buoyant object moves" below). Network ownership is server-owned by default
   (`SetNetworkOwner(nil)`) and can be handed to the nearest client instead
   (`Buoyancy.Ownership`). Goals refresh every frame inside
   `Buoyancy.NearDistance` of a player and on a staggered clock
   (`Buoyancy.UpdateInterval`) everywhere else.
2. **Frozen** — `Anchored = true`, constraints disabled. Objects in the
   middle band (outside their class `SimDistance` but inside
   `Streaming.CacheDistance`) stay rendered but stop simulating, because a
   distant player might still see them.
3. **Cached** — the clone is destroyed and only the lightweight record is
   kept. Re-rendering later re-clones from the pristine template.

## How a buoyant object moves (ship parity)

Floating objects share their motion model with the player-driven ship on
purpose: the ocean only reads as water if everything on it obeys the same
water. The solver itself lives in
`ReplicatedStorage.FloatingObjectGeneration/WaveFloat.luau`, which the ship's
own `BoatManager.CalculateBuoyancy` and this system are both built from.

1. **Real attachments.** Every buoyant clone gets a `FloatingMover` (the point
   `AlignPosition` drives), a `FloatingWaterline` at the bottom of its bounding
   box (the depth reference — the equivalent of the ship's `Main.Center`), and
   four corner attachments (`FloatTopLeft/Right`, `FloatBottomLeft/Right`) that
   the surface is sampled at. They are parented to the hull, so the samples
   roll and pitch with the object instead of probing a fixed world cross, and
   they exist for **every** size: `SlopeBaselineStuds` widens the sample
   baseline (8 studs by default) so a 3-stud crate does not divide a sub-stud
   height difference by 3 and conclude the sea is flat.
2. **The same surface as the visible mesh.** `Buoyancy.HeightSource =
   "ANALYTIC"` (default) evaluates `Gerstner.ComputeTransform` at each sample —
   the wave sum the ocean is displaced with, including the whirlpool dip.
   `"MESH"` samples `HeightLookup.Lookup` at each corner instead (`LookupMethod`
   then applies): literal parity with the ship client, but it searches the
   triangle grid per sample and needs `HeightLookup.ClientInit` on a client.
3. **The ship's depth math.** Front/back sample average = ride height;
   `depth = surfaceY - waterlineY` gates the airborne case (`Solve` returns a
   `nil` height → `AlignPosition.Enabled = false` → gravity does the rest, so
   a prop that launches off a crest splashes back in rather than snapping);
   and the ship's proportional drag term `(centerOfMassY - waterLevel) * 0.075`
   removes vertical energy. `FloatRatio` is the "how sunk is this" knob: the
   mover rides `bboxHeight * (FloatRatio - 0.5)` above the surface.
4. **Slope, not snap.** `atan2(front - back, length)` and `atan2(right - left,
   width)` become pitch/roll, composed *after* a yaw read off physics and then
   deadbanded (`YawDeadbandDegrees`) and smoothed (`YawSmoothing`) — an
   un-deadbanded yaw feeds bobbing noise straight back into the goal and the
   prop slowly spins itself up.
5. **Vertical-only authority.** `ForceLimitMode = PerAxis` with
   `ForceRelativeTo = World` and `MaxAxesForce = (drift, lift, drift)`. In the
   default `Magnitude` mode one cap is shared by all three axes, so any X/Z
   error in the goal quietly eats the budget that should be lifting the hull.
   `DriftReturnForce` is the only horizontal authority: a kicked crate crawls
   back to its own patch of ocean instead of sailing off, and `0` means it
   stays exactly where the player left it.
6. **Two cadences.** Objects within `NearDistance` (150 studs) of a player are
   refreshed every frame with the ship's own gains (`ForceMultiplier` 4,
   `MaxVelocity` 80, `Responsiveness` 12, `TorqueMultiplier` 5000,
   `MaxAngularVelocity` 8, `AngularResponsiveness` 12) — the same
   `PostSimulation` treatment `Workspace/singletons/Ship/Client.client.luau`
   gives the boat. Everything else rides the staggered `UpdateInterval` clock
   (≈8.3 Hz) with the softer `Soft*` gains, and both classes have their own
   per-frame budget. `NearDistance = 0` puts the whole field back on the clock.
7. **Ownership.** `"Server"` (default) keeps 500 props deterministic and
   exploit-proof at the cost of one round trip when a player pushes one.
   `"NearestPlayer"` gives the ship's feel to props: the closest client
   simulates the assembly, limited to `OwnDistance`, capped per client by
   `MaxOwnedPerPlayer`, sticky inside `OwnDistance * OwnKeepRatio`, and
   re-decided only by the streaming cycle because physics handoffs are not
   free. The server still writes every constraint goal; only the simulation
   moves.

Three things made the old motion read as unnatural, and only the first is the
missing attachment points: props under `SmallObjectExtent` (6 studs) got **no**
sample attachments at all, so they sat perfectly level on a 30° slope; the
heights came from `Gerstner:GetApproximateHeight` (`LookupMethod = "FAST"`), a
folded-|sin| stand-in, so they bobbed out of phase with the water they were
floating on; and depth was measured at the bounding-box **centre**, which on a
tall template (a wreck with a mast, a dock with a cabin) reads "clear air under
the keel" — the servo switched off and the object free-fell until `KillDepth`
reclaimed it. Sampling the analytic surface every frame at four widened
attachments fixes all three at once, and it is cheaper per object than the
4× `PRECISE` mesh search it replaces.

## Camera-based caching ("cache when nobody is looking")

- Clients (`StarterPlayerScripts.FloatingObjectsClient`) report camera world
  position + unit look vector over the `CameraReport` `RemoteEvent` roughly
  every 0.5 s from `RunService.PostSimulation`.
- The server (`ServerScriptService.FloatingObjectGenerationServer`) rate
  limits reports per player (`Streaming.CameraMinReportInterval`) and feeds
  them to `FloatingObjectGenerator.SetCameraState`, which hardens the payload
  (type checks, NaN rejection, look-magnitude bounds, absurd-coordinate
  rejection).
- A middle-band object is **seen** if it is inside any fresh camera's view
  cone (`CameraViewConeAngleDeg` half-angle) within `CameraMaxDistance`.
- Unseen objects get `Streaming.OutOfViewGrace` seconds, then are cached.
  (The grace timer lives on the record; it is only reset when the object is
  actually seen or enters simulation range.)
- If **no** camera data is fresh (`CameraDataTimeout`), the system degrades
  gracefully to distance-only: nearby objects stay rendered and frozen.

## Determinism and placement

- The world seed comes from the `Seed` `IntValue` under
  `ReplicatedStorage/Gerstner/Settings` (same source as island generation);
  a fixed fallback is used when absent.
- Player cells (`Placement.CellSize`) are hashed with a decorrelated integer
  hash so the same cell always produces the same records for a given seed.
- Placement rejects island footprints (`ZoneManager` islands plus
  `IslandAvoidPadding`), blockers (`workspace.Map`, `_RisingIslands`),
  existing floating records (octree spacing per class `MinSpacing`), and the
  world spawn (`SpawnSafetyRadius`). Blocked cells are retried after
  `Streaming.ObstacleRetryDelay`; reserved octree footprints are rolled back
  so retries are not self-blocked.

## Despawn and render cap

- Every rendered object lives a deterministic random lifetime in
  `[Despawn.MinLifetime, Despawn.MaxLifetime]`, then despawns permanently
  (record + octree node removed) so the ocean keeps changing.
- Over-cap eviction sorts by render age and player proximity, evicts the
  oldest/farthest records, and puts each evicted record on
  `Despawn.CullCooldown` so it does not immediately respawn.
- An object that physics-squeezes below `Buoyancy.KillDepth` is treated as
  lost and reclaimed.

## Public API

- `FloatingObjectGenerator.Generate()` — starts dynamic streaming.
- `FloatingObjectGenerator.PlaceOne(position, className?)` — renders one
  object at a specific position for debug/admin use.
- `FloatingObjectGenerator.GetCatalog()` — the discovered class catalog.
- `FloatingObjectGenerator.GetStats()` — cached/rendered/buoyant/frozen
  counts, cap, streaming flag, fresh-camera count, `NearBandStuds` +
  `ClientOwnedObjects` (how much of the field the ownership mode has handed
  out), and a `Diagnostics` table (spawn attempts, blocks, clone failures, cap
  deferrals) for production telemetry.
- `FloatingObjectGenerator.SetCameraState(player, cameraPos, cameraLook)` —
  validated camera report entry point (used by the server script).
- `FloatingObjectGenerator.RemovePlayer(player)` — drops camera/player state
  and the leaving player's owned-prop tally.
- `FloatingObjectGenerator.ClearGenerated()` — destroys rendered objects,
  clears records/cells/octree, and stops the streaming loop.

## Edge cases

1. **Missing `ServerStorage.FloatingObjects` / empty** — `Generate()` warns
   and no-ops; discovery retries on a short throttle, so a late-created
   folder starts working without a restart.
2. **Untagged template** — skipped with a one-line warning naming it.
3. **Model directly under root** — fine; same discovery path.
4. **Sub-models** — never treated as templates (recursion stops at Models).
5. **Template with no parts** — skipped.
6. **Overlapping candidate / blocked spot** — cell retried later; reserved
   octree footprints are rolled back between attempts.
7. **Client stops reporting camera** — data goes stale after
   `CameraDataTimeout`; the system degrades to distance-only.
8. **Exploited camera RemoteEvent** — payload hardening + per-player rate
   limit; worst case is "player sees slightly more cached objects".
9. **Externally destroyed model** — `Destroying` connection keeps stats
   consistent and frees the render slot.
10. **World seed `0`/absent** — constant fallback seed keeps determinism.

## Tuning knobs (all in `FloatingObjectConfig`)

- Top level: `TemplatesRoot`, `ObjectTag`, `ClassTags`, `Classes`
  (`Small` / `Medium` / `Large` / `Debris`: `Weight`, `PerCellMin`/`Max`,
  `ClusterRadius`, `MinSpacing`, `SimDistance`, `FloatRatio`),
  `DefaultClassSettings`.
- `Placement`: `CellSize`, `GridJitter`, `ObjectChance`, `SpawnSafetyRadius`,
  `MaxPlacementAttempts`, `ObstaclePadding`, `IslandAvoidPadding`,
  `MaxSpacingRadius`, `MaxIslandRadius`, `WorldRadius`, `RespectWorldRadius`.
- `Streaming`: `Enabled`, `GenerationRadius`, `GenerationInterval`,
  `MaxCellsPerCycle`, `CellsPerYield`, `MaxActivationCellsPerCycle`,
  `MaxSpawnsPerCycle`, `MaxCachesPerCycle`, `MaxRenderedObjects` (hard cap
  `500`), `CacheDistance`, `OutOfViewGrace`, `RespawnCooldown`,
  `ObstacleRetryDelay`, `CameraMaxDistance`, `CameraViewConeAngleDeg`,
  `CameraDataTimeout`, `CameraMinReportInterval`, `CacheTrimInterval`,
  `CellIdleLifetime`, `CacheTrimMargin`.
- `Buoyancy`: `Enabled`, `HeightSource` (`ANALYTIC`/`MESH`), `LookupMethod`,
  `UpdateInterval`, `MaxTargetUpdatesPerFrame`, `ZoneRefreshInterval`,
  `SampleInset`, `SlopeBaselineStuds`, `ForceMultiplier`, `MaxVelocity`,
  `Responsiveness`, `TorqueMultiplier`, `MaxAngularVelocity`,
  `AngularResponsiveness`, `SoftMaxVelocity`, `SoftResponsiveness`,
  `SoftTorqueMultiplier`, `SoftMaxAngularVelocity`, `SoftAngularResponsiveness`,
  `SettleDistance`, `SettleAngleDegrees`, `YawDeadbandDegrees`,
  `YawSmoothing`, `VerticalOnlyForce`, `DriftReturnForce`, `NearDistance`,
  `NearExitRatio`, `NearUpdateInterval`, `NearMaxTargetUpdatesPerFrame`,
  `Ownership`, `OwnDistance`, `OwnKeepRatio`, `MaxOwnedPerPlayer`, `KillDepth`.
  `SmallObjectExtent` is gone: every buoyant object now gets the sample rig,
  and `SlopeBaselineStuds` is what keeps a small hull's slope meaningful.
- `Despawn`: `MinLifetime`, `MaxLifetime`, `CullNearPlayerDistance`,
  `CullCooldown`.

## Headless smoke test

`node tools/smoke-test.js` (from the repo root) runs the real Config +
Generator (plus `WaveFloat`) in a mocked Roblox environment (fengari) with 52
assertions covering catalog discovery, determinism, streaming, LOD
transitions, camera caching, cap eviction, island avoidance, crash paths, and
the buoyancy rig itself: attachment set, hull-bottom depth reference,
per-axis force limits, per-frame cadence in the near band, drift return, MESH
lookups (including that a *failed* lookup must not drop an object), and
ownership handoff/release.
`node tools/check-syntax.js` parses all touched `.luau` files, and
`./tools/node_modules/.bin/stylua --config-path tools/stylua.toml --check <files>`
verifies formatting.

## References (official Roblox docs)

- `AlignPosition` / `AlignOrientation` (non-deprecated constraints) —
  https://create.roblox.com/docs/reference/engine/classes/AlignPosition
- Mover constraints (`ForceLimitMode.PerAxis`, `ForceRelativeTo`,
  responsiveness vs. max force/velocity) —
  https://create.roblox.com/docs/physics/mover-constraints
- `Attachment` (`Position` is part-relative; `WorldPosition` is not — the
  constraint goal is the world one) —
  https://create.roblox.com/docs/reference/engine/classes/Attachment
- `CollectionService` (`AddTag`, `GetTagged`, `GetInstanceAddedSignal`) —
  https://create.roblox.com/docs/reference/engine/classes/CollectionService
- `Model` / pivots (`GetPivot`, `PivotTo`) —
  https://create.roblox.com/docs/studio/pivot-tools
- `Instance` attributes (`SetAttribute`, `GetAttribute`) —
  https://create.roblox.com/docs/reference/engine/classes/Instance
- `BasePart` (`Anchored`, `SetNetworkOwner`) —
  https://create.roblox.com/docs/reference/engine/classes/BasePart
- `RunService` (`PostSimulation`) —
  https://create.roblox.com/docs/reference/engine/classes/RunService
- `RemoteEvent` (client → server camera reports) —
  https://create.roblox.com/docs/reference/engine/classes/RemoteEvent
- `ServerStorage` —
  https://create.roblox.com/docs/reference/engine/classes/ServerStorage
- `WorldRoot` (`GetPartBoundsInRadius`) + `OverlapParams` —
  https://create.roblox.com/docs/reference/engine/classes/WorldRoot
- Streaming (engine-level, complements this system) —
  https://create.roblox.com/docs/workspace/streaming
- `Settings.GRID_SETTINGS.PLANE_OFFSET` is a project module
  (`ReplicatedStorage.Gerstner.Settings`), shared with island generation.
