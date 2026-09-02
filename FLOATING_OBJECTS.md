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
  - `FloatRatio` number attribute — buoyancy strength.
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

1. **Buoyant** — unanchored, network-owned by the server
   (`SetNetworkOwner(nil)`), driven by `AlignPosition` + `AlignOrientation`.
   Targets are refreshed on a staggered clock (`Buoyancy.UpdateInterval`)
   from the Gerstner wave height (`HeightLookup:Lookup` with the configured
   `LookupMethod`, server-safe) and, for larger hulls, real multi-point
   buoyancy samples via `BoatManager.CalculateBuoyancy` for pitch/roll.
2. **Frozen** — `Anchored = true`, constraints disabled. Objects in the
   middle band (outside their class `SimDistance` but inside
   `Streaming.CacheDistance`) stay rendered but stop simulating, because a
   distant player might still see them.
3. **Cached** — the clone is destroyed and only the lightweight record is
   kept. Re-rendering later re-clones from the pristine template.

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
  counts, cap, streaming flag, fresh-camera count, and a `Diagnostics`
  table (spawn attempts, blocks, clone failures, cap deferrals) for
  production telemetry.
- `FloatingObjectGenerator.SetCameraState(player, cameraPos, cameraLook)` —
  validated camera report entry point (used by the server script).
- `FloatingObjectGenerator.RemovePlayer(player)` — drops camera/player state.
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
- `Buoyancy`: `Enabled`, `LookupMethod`, `UpdateInterval`,
  `MaxTargetUpdatesPerFrame`, `ZoneRefreshInterval`, `ForceMultiplier`,
  `MaxVelocity`, `Responsiveness`, `TorqueMultiplier`, `MaxAngularVelocity`,
  `AngularResponsiveness`, `SmallObjectExtent`, `KillDepth`.
- `Despawn`: `MinLifetime`, `MaxLifetime`, `CullNearPlayerDistance`,
  `CullCooldown`.

## Headless smoke test

`node tools/smoke-test.js` (from the repo root) runs the real Config +
Generator in a mocked Roblox environment (fengari) with 32 assertions
covering catalog discovery, determinism, streaming, LOD transitions,
camera caching, cap eviction, island avoidance, and crash paths.
`node tools/check-syntax.js` parses all touched `.luau` files, and
`./tools/node_modules/.bin/stylua --config-path tools/stylua.toml --check <files>`
verifies formatting.

## References (official Roblox docs)

- `AlignPosition` / `AlignOrientation` (non-deprecated constraints) —
  https://create.roblox.com/docs/reference/engine/classes/AlignPosition
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
