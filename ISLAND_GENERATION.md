# Island Generation

Deterministic, server-authoritative island generator for BRINE. It builds closed
terrain meshes from an `EditableMesh`, spawns partially-submerged anchored
structures (shipwrecks, ruins, docks) and floating debris that bobs on the real
Gerstner waves, and tags everything so the existing `ZoneManager` indexes it.

It does **not** modify the Gerstner ocean system, `ZoneManager`, `Helper`,
`BoatManager`, or `Octree`.

## Explorer hierarchy & Rojo paths

```
ReplicatedStorage
└── IslandGeneration            (folder — auto-synced from disk)
    ├── IslandConfig            ModuleScript  src/ReplicatedStorage/IslandGeneration/IslandConfig.luau
    └── IslandGenerator         ModuleScript  src/ReplicatedStorage/IslandGeneration/IslandGenerator.luau
ServerScriptService
└── IslandGenerationServer      Script        src/ServerScriptService/IslandGenerationServer.server.luau
workspace
└── Map (Folder, created if missing)
    └── Island (Model, tagged "Island")
        ├── Center     (Part, 1×1×1, anchored, PrimaryPart)
        ├── Radius     (IntValue, studs)
        ├── Terrain    (MeshPart — the single closed island mesh, anchored + collidable)
        ├── Shipwreck / Ruins / Dock  (Model of anchored Parts, optional)
        └── Barrel / Crate / Buoy / Debris (Model with a Root + 4 "BuoyancyN" attachments, optional)
```

`default.project.json` gains the `ServerScriptService.IslandGenerationServer`
entry; `IslandConfig` / `IslandGenerator` are picked up automatically because the
whole `src/ReplicatedStorage` tree is synced into `ReplicatedStorage`.

## The island contract

`ZoneManager` expects a `Model` tagged `"Island"` containing a `Center`
`BasePart` (the node position) and an optional `Radius` `IntValue`. Radius
resolution order:

1. `Radius` IntValue (user-set).
2. If missing/zero, the **type-category** default range midpoint for procedural
   islands; for user models, the model bounding-box XZ diagonal half (matching
   `ZoneManager`'s own fallback), then the category midpoint.

The generator guarantees every island ends up with a 1×1×1 anchored `Center`
`PrimaryPart` and a valid `Radius` IntValue, then adds the `"Island"` tag and
parents under `workspace.Map` (the folder the ocean depth raycasts include).

## How target / category / weight selection works

- **World seed**: read from the same `ReplicatedStorage.Gerstner.Settings.Seed`
  IntValue the ocean uses. `Settings` reseeds it once when it is `0` and
  persists it, so after `require(Settings)` the value is stable across server
  restarts. A fixed constant fallback (`7919`) keeps things deterministic even
  if the IntValue is ever missing/zero.
- **Per-island RNG**: every island index gets `Random.new(worldSeed + index)`.
  Procedural placement uses a distinct stream `Random.new(worldSeed - 101)` so
  anchor positions don't correlate with island content. `math.random` is never
  used; all randomness (biome, type, radius, structure picks, jitter) derives
  from these seeded `Random` objects. Same seed ⇒ same world.
- **Weighted pick**: biomes, island types, and structures are dictionaries of
  `name = weight`. Missing weights fall back to `IslandConfig.DEFAULT_WEIGHT`
  (`1`); an explicit `0` removes the entry from the pool; if a pool's total
  weight is `0`, the picker falls back to a uniform choice over the keys so a
  misconfigured pool can never block generation.
- Structures are additionally filtered by `Mode` (`Anchored`/`Floating`) and by
  `MinRadius`/`MaxRadius`, and each island only attempts the configured
  `MaxStructuresPerIsland` / `MaxFloatingObjectsPerIsland`.

## How the mesh is built

- One heightmap over the island diameter: `fBm` of Roblox `math.noise` (seeded
  per island) plus a **radial falloff** so terrain rises at the center and
  trends to the water plane at the rim. A flattened beach band and an
  underwater shelf make the shoreline meet the water naturally instead of as a
  cliff. `Atoll` kind builds a submerged lagoon with a raised ring.
- Vertices are tinted by biome + height + slope: sand near the water, grass
  inland, rock on steep faces (computed from neighbor heights) and at altitude,
  snow above `SnowLine` (gentle slopes only), plus subtle deterministic noise
  to break banding.
- Geometry (all authored in **local space**, water at local Y 0):
  1. a round top surface (grid cells beyond `radius * 1.08` are dropped),
  2. a **skirt** wall around every boundary vertex dropping to `-SkirtDepth`
     (28 — deeper than the ocean's 15-stud depth ray, so shore foam/depth
     rendering always hits land),
  3. a bottom triangle fan closing the solid.
  That yields a **single** watertight, collidable `MeshPart` (the "1 part"
  target; fallback parts only appear on mesh failure).
- The `EditableMesh` is turned into a part with
  `AssetService:CreateMeshPartAsync(Content.fromObject(em), { CollisionFidelity =
  PreciseConvexDecomposition })`, retried at `Default` fidelity, and finally a
  plain submerged cylinder part if mesh creation fails. Vertex colors use the
  modern `AddColor` + `SetFaceColors` path (smooth interpolation).
- Work is batched: mesh vertex/face creation yields every
  `VertexBudgetPerFrame` items and the orchestrator yields between islands, so a
  large world never freezes the server.
- A cheap distance LOD (`Generation.LOD`) uses a coarser mesh past `Distance`.
- The whole mesh is authored relative to the water plane at
  `PlaneOffset = Settings.GRID_SETTINGS.PLANE_OFFSET.Y` (25) — nothing is
  hardcoded to `0`.

## Anchored vs floating structures

- **Anchored** (`Shipwreck`, `Ruins`, `Dock`): anchored, `CanCollide`, built
  from simple parts (no external assets). Water structures raycast the seabed
  and are deliberately half-submerged — wrecks rest on the bottom with the
  splayed hull/mast above water; docks sit with their deck `AboveWater` and
  posts down to the seabed; ruins only place on dry land and embed slightly.
  All live under `workspace.Map`, so depth raycasts see them.
- **Floating** (`Barrel`, `Crate`, `Buoy`, `Debris`): a small root part with 4
  corner `Attachment`s named `Buoyancy1..4`. A shared `RunService.Heartbeat`
  loop round-robins through them (only `Floating.UpdatesPerFrame` objects are
  sampled per frame) and calls **`BoatManager.CalculateBuoyancy`**, which in
  turn uses **`HeightLookup.Lookup`** — the exact boat buoyancy path. Anchored
  mode (default, stable) updates only Y + wave pitch/roll while keeping XZ and
  yaw fixed so debris can never drift into boats/players. An optional
  `Floating.EnablePhysics` mode makes the root unanchored and drives it with a
  mass-normalized `VectorForce` spring on Y plus a soft XZ leash and
  `AlignOrientation` for wave tilt.

## Placement & overlap checks

- User-placed anchors (`Island` models with `Center`) are always honored and
  processed first, sorted by position for stable indices.
- Procedural islands use a **jittered grid** within `Placement.WorldRadius`,
  skipping `SpawnSafetyRadius` around the origin. Each candidate is rejected
  unless clear in an `Octree`: minimum center distance is
  `radiusA + radiusB + SpacingPadding` (the `Octree` from
  `ReplicatedStorage.Octree`, reused, not rewritten).
- Structures use a second octree keyed by footprint (plus
  `StructuresOverlapPadding`). They also raycast with an "obstacle" param that
  excludes both `Map` (terrain) and `Ocean` (water surface), so a boat or
  player occupying the spot rejects the placement — structures can't spawn on
  boats or players. Land/ruin and water/dock spots further require the
  raycasted surface to be above/below the water appropriately.

## Determinism

Every terrain vertex comes from `math.noise(seeded)`; every choice comes from a
seeded `Random`. Time never enters generation, so the same world seed and
island index always produce the same island. Floating-object motion is time
based but purely cosmetic. `Settings.Seed == 0` is handled by `Settings`
(reseed + persist) before we read it.

## Regeneration / stale state

`IslandGenerator.ClearGenerated()` destroys everything created (whole procedural
island models, and content added to user anchor models), clears both octrees,
disconnects the floating-object heartbeat, and resets the `IslandProcessed`
flags on surviving user anchors. Call it from the command bar / an admin tool
and then `IslandGenerator.Generate()` for a clean deterministic rebuild.

## Edge cases

1. **Missing Center / Radius** — missing `Center` logs a warning and skips;
   missing/zero `Radius` falls back to bounding box, then category default.
2. **All-zero / missing weights** — explicit `0` removes an entry; a pool with
   total weight `0` falls back to uniform; missing weight = `DEFAULT_WEIGHT`.
3. **Overlapping procedural placements** — octree rejection with padding;
   non-fitting spots are simply skipped.
4. **Structures that don't fit** — radius-gated (`MinRadius`/`MaxRadius`) and
   each type tries multiple candidate spots before giving up.
5. **Floating objects colliding with islands/players** — they spawn only over
   water (terrain raycast below water), reject occupied footprints, and default
   anchored bobbing keeps `CanCollide = false` and zero horizontal drift.
6. **Mesh creation / closing failures** — fidelity retry → solid cylinder
   fallback; every island still leaves a collidable, raycastable result.
7. **PLANE_OFFSET changes** — shoreline height reads
   `Config.PlaneOffset` which mirrors `Settings.GRID_SETTINGS.PLANE_OFFSET.Y`.
8. **Regeneration determinism** — seed + index driven; `ClearGenerated` resets
   all state.
9. **World seed 0** — reseeded/persisted by `Settings`; constant fallback.
10. **Large worlds** — batched, yielding mesh build + per-island waits.
11. **Structures spawning inside boats** — the obstacle raycast excludes Map and
    Ocean, so boats/players are detected and spots rejected.
12. **Respawn/restart stale state** — content is server-owned/anchored and
    tracked; `ClearGenerated` tears down all of it, leaving user anchors intact.

## Tuning knobs (all in `IslandConfig`)

- `DEFAULT_WEIGHT`, `PlaneOffset`, `ShelfDepth`, `SkirtDepth`.
- `BiomeCategories`: weights, full vertex palette, snow line, rock steepness,
  beach height, rock altitude, and the per-biome structure weight pool.
- `TypeCategories`: weights, `Kind`, `RadiusMin/Max`, `MaxHeight`.
- `StructureDefinitions`: weight, mode, land/water category, footprint, radius
  range, draft/above-water/riding offsets, color/material.
- `Placement`: procedural toggle, world radius, cell size + jitter, spawn
  safety radius, inter-island padding, attempts, per-island + global structure
  caps, overlap padding, ground embed.
- `Generation`: mesh spacing + resolution clamp, noise octaves, batching
  budgets, collision fidelity, terrain material, LOD distance/factor.
- `Floating`: physics toggle, collision toggle, per-frame update budget, and
  (physics mode) spring/leash tuning.
