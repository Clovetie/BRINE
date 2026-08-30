# Island Generation

Streams **premade** islands into the BRINE ocean world. The generator does
**not** generate geometry, noise, meshes, or structures — islands are authored by
hand as complete `Model`s under `ServerStorage.Islands`. The generator discovers
those templates, creates deterministic cached island records around moving
players, and only clones/renders a record when a player gets close enough to see
it rise from the ocean.

The rendered amount is capped by `IslandConfig.Streaming.MaxRenderedIslands`
(default `200`). The cached/generated record count can keep growing as players
travel, but the amount of actual island `Model`s in `Workspace` stays bounded.

## Premade island folder (`ServerStorage.Islands`)

Islands are stored server-only in `ServerStorage` so templates never replicate to
clients until cloned into the world:

```
ServerStorage
└── Islands                        (Config.PremadeIslandsRoot)
    ├── Jungle                     (biome folder)
    │   ├── Islet/…/MyIsland       (island Models at ANY folder depth)
    │   ├── SmallIsland
    │   └── IslandsFolder1         (nested folder — recursion handles it)
    │       └── AnotherIsland
    ├── Snow
    ├── Desert
    └── LooseIsland                 (Model directly under root → Config.DefaultBiome)
```

Rules the generator follows:

- Each **Folder directly under the root** is one biome (its `Name`).
- Models are discovered **recursively** through folders at any depth. The
  generator does **not** descend into a `Model` — a model's children (docks,
  ruins, sub-models) are island components, not separate templates.
- A biome folder with no island `Model`s is skipped.
- A `Model` sitting directly under the root (not in any biome folder) is assigned
  `Config.DefaultBiome`.
- Optional per-biome weights come from `Config.BiomeWeights`; weight `<= 0`
  removes that biome.

## Runtime hierarchy

```
ReplicatedStorage
└── IslandGeneration
    ├── IslandConfig            (ModuleScript)
    └── IslandGenerator         (ModuleScript)

ServerScriptService
└── IslandGenerationServer      (Script)

workspace
├── _RisingIslands              (created on demand for rise/sink tweens)
└── Map                         (created if missing)
    └── TheIsland               (Model, moved here after rising, tagged "Island")
        ├── Center              (BasePart — PrimaryPart, node anchor)
        ├── Radius              (IntValue, studs)
        └── …                   (the premade template, cloned as-is)
```

Cached islands that are not currently rendered are just Lua records in the
server module, not hidden model clones. This keeps idle cache cost low.

## The island contract

`ZoneManager` expects a `Model` tagged `"Island"` containing a `Center`
`BasePart` and an optional `Radius` `IntValue`. The generator enforces this at
clone time:

- **Center** — uses the template's `Center` `BasePart` if present (and makes it
  anchored, non-collidable, and the `PrimaryPart`). If missing, it creates a
  `1×1×1` anchored, transparent `Part` at the model's bounding-box center.
- **Radius** — uses the template's `Radius` `IntValue` if present; otherwise the
  XZ bounding-box half (`(GetExtentsSize()*XZ).Magnitude / 2`); otherwise
  `Config.DefaultRadius`.
- The final `Center` is laid down at the water plane
  (`Config.PlaneOffset = Settings.GRID_SETTINGS.PLANE_OFFSET.Y`, default `25`).
- A rising/sinking island lives temporarily under `workspace._RisingIslands` and
  is not tagged. After the rise tween completes, it moves to `workspace.Map` and
  receives the `"Island"` tag so `ZoneManager` indexes the final position.
- On despawn/sink, the tag is removed before the model leaves `workspace.Map` so
  `ZoneManager` can remove the stale octree node.

## Dynamic streaming and caching

`IslandGenerator.Generate()` now starts a background streaming loop instead of a
single finite scatter pass:

1. Every `Streaming.GenerationInterval` seconds, each player's current cell is
   scanned outward to `Streaming.GenerationRadius`.
2. Unknown cells are evaluated deterministically using the world seed and cell
   coordinates. The result is cached as either an island record or an empty cell.
3. Accepted island records reserve their footprint in an octree immediately, so
   future cells avoid overlaps even before any model is cloned.
4. Records near players are activated. Activation clones the premade template,
   plays the rise sound placeholder, tweens the model upward, then publishes it
   into `workspace.Map`.
5. Rendered islands are capped by `Streaming.MaxRenderedIslands`. If a new island
   needs to render while the cap is full, the farthest/oldest rendered generated
   island is culled first. Render-cap culls are cached and can re-render later.

Optimization choices:

- The cache is lightweight data, not thousands of hidden instances.
- Generation and activation are budgeted by `MaxCellsPerCycle`, `CellsPerYield`,
  `MaxActivationCellsPerCycle`, and `MaxActivationsPerCycle`.
- Broadphase obstacle checks use `Workspace:GetPartBoundsInRadius` with
  `OverlapParams`. `Map`, `Ocean`, currently rising/sinking islands, and player
  characters are excluded from the query.
- If a boat/prop/baseplate blocks a deterministic candidate, that cell retries
  after `Streaming.ObstacleRetryDelay` instead of being permanently skipped.

## Rising animation

`IslandConfig.Rising` controls the reveal:

- The close-enough test uses horizontal player distance to the final island
  center: `Radius + Rising.TriggerDistance`.
- The server moves the clone to `workspace._RisingIslands`, places it
  `Rising.HiddenDepth` studs below its final pivot, and tweens a `CFrameValue`
  with `TweenService` to drive `Model:PivotTo()`.
- After completion, the island moves to `workspace.Map` and is tagged `"Island"`.
- Replace `SoundId = "rbxassetid://0"` in `IslandConfig.Rising` with your own
  uploaded rise sound id.

## Despawn and sinking animation

`IslandConfig.Despawn` controls island cleanup:

- A rendered island gets a deterministic lifetime between
  `Despawn.MinLifetime` and `Despawn.MaxLifetime` (default **35–60 minutes**).
- When the lifetime expires, the island permanently despawns for that server
  session.
- If a despawning island is within `Radius + Despawn.NearPlayerDistance` of a
  player, it sinks with TweenService first; if nobody is close, it is removed
  immediately for performance.
- If the rendered cap is reached, the generator culls the farthest/oldest active
  island. Cap culls are **not permanent**; the cached record remains and may rise
  again later after `Despawn.CullCooldown`.
- Replace `SoundId = "rbxassetid://0"` in `IslandConfig.Despawn` with your own
  uploaded sink sound id.

## Public API

- `IslandGenerator.Generate()` — starts dynamic streaming (or static fallback if
  `Streaming.Enabled = false`).
- `IslandGenerator.PlaceOne(centerPos, index?)` — clones/activates one random
  premade island at a specific position for debug/admin use.
- `IslandGenerator.GetCatalog()` — returns the discovered biome catalog.
- `IslandGenerator.GetStats()` — returns cached/rendered counts and whether the
  streaming loop is running.
- `IslandGenerator.ClearGenerated()` — destroys generated island models and
  clears the streaming/cache/octree state. User-dropped anchors in
  `workspace.Map` are preserved.

## Edge cases

1. **Missing `ServerStorage.Islands` / empty** — `Generate()` warns and no-ops.
2. **Empty/nested biome folders** — empty folders are skipped; arbitrarily deep
   folder nesting is recursed.
3. **Model directly under root** — assigned `Config.DefaultBiome`.
4. **Component sub-models** — recursion does not descend into a `Model`, so
   structures inside an island are not mistaken for separate templates.
5. **Missing `Center`** — a contract-compliant Center is created at clone time.
6. **Missing/zero `Radius`** — bounding-box half, then `Config.DefaultRadius`.
7. **Overlapping candidate** — cached as an empty cell and never forced into the
   world.
8. **Temporary obstacle** — retried later, because boats/props can move.
9. **Existing `Map` islands / anchors** — seeded into the octree so streaming
   avoids user-placed islands.
10. **`PLANE_OFFSET` changes** — `Config.PlaneOffset` mirrors ocean settings.
11. **World seed `0`** — reseeded/persisted by `Settings`; constant fallback.
12. **Zone cleanup** — `ZoneManager` now tracks one island node per model and
    removes it when the `"Island"` tag is removed or the model is destroyed.

## Tuning knobs (all in `IslandConfig`)

- `DEFAULT_WEIGHT`, `PlaneOffset`, `PremadeIslandsRoot`, `BiomeWeights`,
  `DefaultBiome`, `DefaultRadius`, `CenterPartName`, `RadiusValueName`,
  `CenterPartSize`.
- `Placement`: `WorldRadius`, `CellSize`, `GridJitter`, `SpawnSafetyRadius`,
  `SpacingPadding`, `MaxPlacementAttempts`, `ObstaclePadding`, `MaxIslandRadius`,
  `AnchorPlacedIslands`.
- `Streaming`: `Enabled`, `GenerationRadius`, `CellSize`, `IslandChance`,
  `GenerationInterval`, `MaxCellsPerCycle`, `CellsPerYield`,
  `MaxActivationCellsPerCycle`, `MaxActivationsPerCycle`,
  `MaxRenderedIslands`, `ObstacleRetryDelay`, `RespectWorldRadius`.
- `Rising`: `Enabled`, `TriggerDistance`, `HiddenDepth`, `TweenTime`,
  `EasingStyle`, `EasingDirection`, `SoundId`, `SoundVolume`,
  `SoundRollOffMaxDistance`, `SoundCleanupDelay`.
- `Despawn`: `MinLifetime`, `MaxLifetime`, `NearPlayerDistance`,
  `CullNearPlayerDistance`, `CullCooldown`, `SinkDepth`, `TweenTime`,
  `EasingStyle`, `EasingDirection`, `SoundId`, `SoundVolume`,
  `SoundRollOffMaxDistance`, `SoundCleanupDelay`.

## References (official Roblox docs)

- Scripting overview — https://create.roblox.com/docs/scripting
- Task scheduler (`task.spawn`, `task.wait`) — https://create.roblox.com/docs/scripting/scheduler
- `ServerStorage` — https://create.roblox.com/docs/reference/engine/classes/ServerStorage
- `Instance` (`GetChildren`, `GetDescendants`, `FindFirstChild`) — https://create.roblox.com/docs/reference/engine/classes/Instance
- `Model` / pivots (`GetPivot`, `PivotTo`) — https://create.roblox.com/docs/studio/pivot-tools
- `CollectionService` (`AddTag`, `RemoveTag`, tag signals) — https://create.roblox.com/docs/reference/engine/classes/CollectionService
- `TweenService` — https://create.roblox.com/docs/reference/engine/classes/TweenService
- `Sound` — https://create.roblox.com/docs/reference/engine/classes/Sound
- `Workspace` / `WorldRoot` (`GetPartBoundsInRadius`) — https://create.roblox.com/docs/reference/engine/classes/WorldRoot
- `OverlapParams` (`FilterDescendantsInstances`, `FilterType`, `MaxParts`, `RespectCanCollide`) — https://create.roblox.com/docs/reference/engine/datatypes/OverlapParams
- `Settings.GRID_SETTINGS.PLANE_OFFSET` is a project module (`ReplicatedStorage.Gerstner.Settings`), mirrored by `IslandConfig.PlaneOffset`.
