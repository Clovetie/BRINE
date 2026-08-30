# Island Generation

Scatters **premade** islands into the BRINE ocean world. The generator does
**not** generate geometry, noise, meshes, or structures — islands are authored by
hand as complete `Model`s under `ServerStorage.Islands`, and the generator
merely discovers, picks, and clones them into `workspace.Map`.

It does **not** modify the Gerstner ocean system, `ZoneManager`, `Helper`,
`BoatManager`, or `Octree`.

## Premade island folder (ServerStorage.Islands)

Islands are stored server-only in `ServerStorage` so they never replicate to
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
  `Config.DefaultBiome` (edge case).
- Optional per-biome weights come from `Config.BiomeWeights`; weight `<= 0`
  removes that biome.

## Explorer hierarchy

Create these instances in Studio (a Rojo project mapping is optional — the
scripts work when pasted in as-is):

```
ReplicatedStorage
└── IslandGeneration            (Folder)
    ├── IslandConfig            (ModuleScript)
    └── IslandGenerator         (ModuleScript)

ServerScriptService
└── IslandGenerationServer      (Script)

workspace
└── Map                         (Folder, created if missing)
    └── TheIsland               (Model, cloned from ServerStorage.Islands, tagged "Island")
        ├── Center              (BasePart — PrimaryPart, the node anchor)
        ├── Radius              (IntValue, studs)
        └── …                   (the rest of the premade template, cloned as-is)
```

`IslandConfig.luau` and `IslandGenerator.luau` go inside the `IslandGeneration`
folder as ModuleScripts; `IslandGenerationServer.server.luau` is a Script under
`ServerScriptService`. That map is the whole integration.

## The island contract

`ZoneManager` expects a `Model` tagged `"Island"` containing a `Center`
`BasePart` (the node position — `Center.Position`) and an optional `Radius`
`IntValue`. Because islands are premade, the generator enforces the contract at
clone time:

- **Center** — uses the template's `Center` `BasePart` if present (and makes it
  anchored, non-collidable, and the `PrimaryPart`). If missing, it creates a
  `1×1×1` anchored, transparent `Part` at the model's bounding-box center and
  makes it the `PrimaryPart`.
- **Radius** — uses the template's `Radius` `IntValue` if present; otherwise the
  XZ bounding-box half (`(GetExtentsSize()*XZ).Magnitude / 2`, matching
  `ZoneManager`'s own fallback); otherwise `Config.DefaultRadius`.
- The placed island's Center is laid down at the water plane
  (`Config.PlaneOffset = Settings.GRID_SETTINGS.PLANE_OFFSET.Y`, default 25), so
  the template's Center should be authored at its intended waterline.
- Tagged `"Island"` and parented under `workspace.Map` (the folder the ocean
  depth rays include).

## Discovery, weighting, and determinism

- **Catalog** is built from `ServerStorage.Islands` (see above). Biomes are
  auto-discovered; weights are `Config.BiomeWeights[name]` or
  `Config.DEFAULT_WEIGHT`.
- **World seed** is read from the same
  `ReplicatedStorage.Gerstner.Settings.Seed` `IntValue` the ocean uses
  (`Random.new(worldSeed + index)` for per-island picks). The placement/scatter
  stream uses `Random.new(worldSeed - 101)` so positions don't correlate with
  template picks.
- **Weighted pick**: a cumulative weighted pick from a seeded `Random`. Missing
  weight → `DEFAULT_WEIGHT`; explicit `0` removes the entry; a pool with total 0
  falls back to a uniform pick. `math.random()` is never used on the
  deterministic path.

## Placement & collision safety ("NEVER collides")

- **Jittered grid** of candidate cells within `Placement.WorldRadius`, skipping
  `Placement.SpawnSafetyRadius` around origin. Jitter makes it look natural.
- **The check happens BEFORE the island is parented into the world.** For each
  candidate, `isSpotClear` verifies:
  1. **Island overlap (octree)** — the candidate center must be at least
     `radiusA + radiusB + Placement.SpacingPadding` from every already-placed
     island. Existing `Map` models are seeded into the octree first so the
     scatter can't overlap user-dropped anchors or a previous run.
  2. **Obstacles via broadphase** — `Workspace:GetPartBoundsInRadius(pos,
     radius + ObstaclePadding, overlapParams)` returns any part that is **not** a
     descendant of `Map` or `Ocean`. A non-empty result (boat, player, prop,
     baseplate) rejects the spot.
- If a candidate collides, the generator **re-rolls** the position/template up to
  `MaxPlacementAttempts` per cell (i.e. it finds a new spot), instead of forcing
  an island into a bad spot. Cells that never find a clear spot are skipped.
- The ocean is excluded so water planes are never treated as obstacles; islands
  are meant to rise out of them.

## Public API

- `IslandGenerator.Generate()` — catalog + seed octree + scatter pass.
- `IslandGenerator.PlaceOne(centerPos, index?)` — clone a single random premade
  island at a position (for debug/admin drops).
- `IslandGenerator.GetCatalog()` — the discovered biome catalog.
- `IslandGenerator.ClearGenerated()` — destroy every island the generator
  placed and reset the placement octree; user-dropped anchors are preserved.
  Followed by `Generate()` to rebuild deterministically.

## Edge cases

1. **Missing `ServerStorage.Islands` / empty** — `Generate()` warns and no-ops
   (no hanging `WaitForChild`).
2. **Empty/nested biome folders** — empty folders are skipped; arbitrarily deep
   folder nesting is recursed.
3. **Model directly under the root** — assigned `Config.DefaultBiome`.
4. **Component sub-models** — recursion does not descend into a `Model`, so a
   structure sub-model inside an island is not mistaken for a separate template.
5. **Missing `Center`** — a contract-compliant Center is created at the model's
   bounding-box center.
6. **Missing/zero `Radius`** — bounding-box half, then `Config.DefaultRadius`.
7. **Colliding candidate** — re-rolled up to `MaxPlacementAttempts`, else skipped
   (never overlapping).
8. **Existing `Map` islands / anchors** — seeded into the octree so the scatter
   avoids them.
9. **`PLANE_OFFSET` changes** — `Config.PlaneOffset` mirrors
   `Settings.GRID_SETTINGS.PLANE_OFFSET.Y`; nothing hardcodes `25`.
10. **Regeneration determinism** — seed + discovery driven; `ClearGenerated`
    resets all state and catalog so a rebuild is clean.
11. **World seed `0`** — reseeded/persisted by `Settings`; constant fallback.

## Tuning knobs (all in `IslandConfig`)

- `DEFAULT_WEIGHT`, `PlaneOffset`, `PremadeIslandsRoot`, `BiomeWeights`,
  `DefaultBiome`, `DefaultRadius`, `CenterPartName`, `RadiusValueName`,
  `CenterPartSize`.
- `Placement`: `WorldRadius`, `CellSize`, `GridJitter`, `SpawnSafetyRadius`,
  `SpacingPadding`, `MaxPlacementAttempts`, `ObstaclePadding`, `MaxIslandRadius`,
  `AnchorPlacedIslands`.

## References (official Roblox docs)

- Scripting overview — https://create.roblox.com/docs/scripting
- `ServerStorage` — https://create.roblox.com/docs/reference/engine/classes/ServerStorage
- `Instance` (GetChildren / GetDescendants / FindFirstChild) — https://create.roblox.com/docs/reference/engine/classes/Instance
- `Model` (Clone / GetBoundingBox / GetExtentsSize / PivotTo) — https://create.roblox.com/docs/reference/engine/classes/Model
- `CollectionService` (AddTag) — https://create.roblox.com/docs/reference/engine/classes/CollectionService
- `Workspace` / `WorldRoot` (GetPartBoundsInRadius) — https://create.roblox.com/docs/reference/engine/classes/WorldRoot
- `OverlapParams` (ExcludeInstances / MaxParts / RespectCanCollide) — https://create.roblox.com/docs/reference/engine/datatypes/OverlapParams
- `Settings.GRID_SETTINGS.PLANE_OFFSET` is a project module (`ReplicatedStorage.Gerstner.Settings`), mirrored by `IslandConfig.PlaneOffset`.
