# Island Generation — Brainstorm + Prompt for the Next AI

This document is **design, not implementation**. It summarizes how island
generation should fit into the existing BRINE ocean project and ends with a
**paste-ready prompt** the next AI can use to implement it.

---

## Part 1 — Brainstorm

### 1. Existing integration points (read these first)

The ocean system already has hooks for islands. The generator should not
reinvent them.

| Thing | Where it lives | What it expects |
| --- | --- | --- |
| Island anchor contract | `ZoneManager` (`Serial/ZoneManager/init.luau`) | A `Model` whose `Center` is a `BasePart` (the primary part) and which optionally has a `Radius` `IntValue`. If `Radius` is missing it uses `(Island:GetExtentsSize()*XZ).Magnitude / 2`. |
| Island discovery | `ZoneManager` | Models tagged `"Island"` via `CollectionService`, **or** placed directly under `workspace.Map` (it scans both). |
| Depth / shore detection | `Helper.luau` | Raycasts down into `workspace.Map` to know where the ocean is shallow. Islands must live in `workspace.Map` for this to work. |
| Wave height for structures | `HeightLookup.Lookup(...)` | Returns the ocean surface height for an XZ point (already adds `PLANE_OFFSET` in `Settings`, default `25`). |
| Buoyancy math | `BoatManager.CalculateBuoyancy(...)` | Given 4 sample points + dimensions, returns a target `Vector3`, orientation `CFrame`, and clamped depth. Reuse this pattern for floating objects. |
| Wave/zone influence | `ZoneManager.GetZoneParameters`, `GetZoneMultipliers` | Structures/boats near islands should read/damp waves through the island's `Radius`. |
| Global seed | `Settings.Seed` | Deterministic world. Use `Random.new(seed + islandIndex)` for per-island determinism. |
| Spatial queries | `Octree` | Already used by `ZoneManager` for islands/zones. Can be reused for placement overlap queries. |

Important: the water surface is **y = `Settings.GRID_SETTINGS.PLANE_OFFSET`**
(default `25`). Island geometry and structures must be built around that
height, not around y = 0.

### 2. Goals and non-goals

**Goals**
- Generate seamless, optimized, deterministic islands that integrate with the
  ocean's existing shore/depth/boat behavior.
- Use a simple `Island` model: `Center` (1x1 stud, primary part) + `Radius`
  (`IntValue`), matching what `ZoneManager` already reads.
- Support biome/type categories with **rarity weights** (default weight when
  none provided).
- Generate **anchored, slightly submerged structures** (explorable, mostly
  above water) and **unanchored floating objects** (bob on waves).
- Keep it readable and not overengineered.

**Non-goals / caveats**
- Do **not** rewrite the Gerstner ocean, `ZoneManager`, `Helper`, `BoatManager`,
  or `Octree`.
- Do **not** generate islands using `workspace.Terrain` (the ocean uses
  MeshParts; boats/enemies/players swim on mesh, not terrain).
- Do **not** introduce heavy grids of individual blocks (1000+ Parts per
  island is not "seamless/optimized").
- Do **not** add permanent welds or teleports; structures should be either
  anchored or buoyant, not glued to players.

### 3. Proposed architecture

Keep it to **one config module + one generator module + one server script**
(optionally a small structure module). Something like:

```
ReplicatedStorage
└── IslandGeneration [Folder]
    ├── IslandConfig [ModuleScript]     -- categories, weights, shapes, structure templates
    └── IslandGenerator [ModuleScript]  -- noise, mesh building, placement, weighted pick (pure-ish)

ServerScriptService
└── IslandGenerationServer [Script]     -- orchestrates spawn/cleanup, owns runtime state
```

Rules of thumb:
- `IslandConfig` is data-only (no deep logic).
- `IslandGenerator` can be required by both server and (optionally) a client
  preview, but it should not depend on runtime services beyond `AssetService`
  when actually creating meshes.
- `IslandGenerationServer` owns all spawning, tagging, and lifecycle.

### 4. Island model contract

```
Island (Model)  -- PrimaryPart = Center
├── Center  (BasePart, Size=1x1x1, Anchored, the center at island origin)
├── Radius  (IntValue)                -- exact size in studs, set by the user
├── Category (StringValue?)           -- diagnostic; set by generator
├── Seed     (IntValue?)              -- diagnostic; set by generator
├── Body    (MeshPart or Folder)      -- the visible/collidable island terrain
└── Structures (Folder)               -- anchored water structures + floating objects
```

- Place every island under `workspace.Map` so `Helper` depth raycasts see it.
- Tag it `"Island"` with `CollectionService` so `ZoneManager` indexes it.
- `Center` is the anchor `BasePart` used by `ZoneManager` (`Center.Position`).
- `Radius` is the authoritative radius; `ZoneManager` uses it to build the
  island node in `ISLAND_TREE`.
- The island surface should sit around the ocean plane (`PLANE_OFFSET`), with a
  solid base descending below water. The shoreline slope should cross
  `PLANE_OFFSET` inside the radius so `Helper` depth rays actually hit the
  island and activate shore coloring.

### 5. Categories, biomes, types, rarity weights

There are two useful dimensions:

**Biome / environment** — decides palette, texture/material, structure pool,
and sometimes noise style. Examples: `Jungle`, `Snow`, `Desert`, `Tropical`,
`Rocky`.

**Type / shape** — decides size range, height range, and silhouette.
Examples: `Islet`, `Atoll`, `Mainland`, `Volcano`, `Lagoon`.

Design:
- `Biome` can either be chosen globally (one world biome) or per-island via
  weights. Per-island weights are more fun and match the user's "categories
  may be separated in biomes/types".
- Each entry has `Weight`. If `Weight` is missing/`nil`, use a global
  `DEFAULT_WEIGHT` (recommend `1`) so categories are effectively unweighted.
- Use a **cumulative weighted pick** from a seeded `Random`. Never use
  `math.random()` directly.
- Structure entries also have `Weight` (rarity) + default. Some structures can
  be gated behind attributes such as `MinRadius`, `MaxRadius`, `Weight`,
  `OnlyOnLand`, `OnlyInWater`.

Example config shape (not final code):

```lua
return {
    DEFAULT_WEIGHT = 1,
    PLANE_OFFSET = 25,          -- should mirror Settings.GRID_SETTINGS.PLANE_OFFSET
    RANDOM_SEED_OFFSET = 1000,

    BiomeCategories = {
        Jungle = { Weight = 12, GroundColors = {...}, StructureWeights = {...} },
        Snow   = { Weight = 6,  GroundColors = {...}, StructureWeights = {...} },
        Desert = { Weight = 3,  GroundColors = {...}, StructureWeights = {...} },
        -- no Weight = default weight
    },

    TypeCategories = {
        Islet  = { Weight = 40, RadiusMin = 15,  RadiusMax = 40,  MaxHeight = 4  },
        Atoll  = { Weight = 20, RadiusMin = 40,  RadiusMax = 90,  MaxHeight = 6  },
        Mainland = { Weight = 10, RadiusMin = 90, RadiusMax = 220, MaxHeight = 10 },
    },
}
```

### 6. Terrain / mesh generation

**Recommended: EditableMesh heightmap → one `MeshPart` per island.**

1. Build a grid over the island's radius at a chosen resolution (e.g. 1–4 studs).
2. For each XZ vertex, compute height using layered deterministic noise:
   `height = fBm(noise) * heightScale * falloff(distance / radius)`.
3. Falloff should reach 0 near the edge so the island meets water cleanly.
4. Paint vertex colors from the chosen biome (sand near water, grass/cliff/
   snow by height + slope).
5. Create an `AssetService:CreateEditableMesh`, add vertices/triangles, then
   `AssetService:CreateMeshPartAsync(Content.fromObject(em), {
       CollisionFidelity = Enum.CollisionFidelity.Hull,
       RenderFidelity = Enum.RenderFidelity.Automatic,
   })`.
6. Set the `MeshPart.Parent = island.Body`, `Anchored = true`,
   `CanCollide = true`, `CastShadow = true` as appropriate.
7. Close/skirt the underside so the island looks solid from below and the
   water does not appear to end at the top surface.

Why this approach:
- Fewer instances (1 island ≈ 1–3 MeshParts instead of hundreds of blocks).
- Smooth, organic coastlines without unions.
- Reuses EditableMesh APIs already used by `Setup` in the ocean system.

**Alternative rejected for now**: voxel blocks + greedy meshing. It is robust
but heavier to build and harder to keep "seamless" for large islands.

**Mesh safety / budget**
- Do not create hundreds of MeshParts in one frame.
- Use `task.spawn` / a queue; generate at most N islands per tick.
- `CreateMeshPartAsync` yields; schedule the next step after it returns.
- Consider a simple LOD: low-detail far islands, high-detail near the camera.
  Start with one detail level, add LOD only if needed.

### 7. Noise / shaping

- Use `math.noise` or a small custom 2D noise; keep it seeded and consistent
  per island: `Random.new(seed + islandIndex)`.
- Use fractional Brownian motion (several octaves) for natural terrain.
- Use a radial falloff (`clamp(1 - d/r, 0, 1)` or smoothstep) so islands taper
  to shore.
- Add mild XZ distortion to the radius so islands are not perfect circles.
- Per-biome tweaks: `Jungle` uses higher frequency + lush greens; `Snow` uses
  smoother hills + white/blue; `Volcano` uses sharp peaks.

### 8. Placement algorithm

There are two scenarios; support both.

**A. User-placed anchors** (matches "Radius is set by me")
- The user drops an `Island` Model with `Center` + `Radius` and the generator
  fills it in.

**B. Procedural placement** (optional / default when no anchors exist)
- Use a **jittered grid** or **Poisson-disc / Blue-noise** sample to get island
  centers with guaranteed spacing.
- Minimum center distance = `radiusA + radiusB + Padding`.
- Use the existing `Octree` to query nearby islands before accepting a spot.
- Constrain placement to a configurable world radius / spawn area.
- For infinite/open worlds, generate deterministically by world cell (hash cell
  → island seed) so islands don't depend on player travel direction.

### 9. Structure generation

Two classes:

**9a. Anchored, slightly submerged water structures (explorable)**
- Examples: shipwrecks, ruined towers, cave mouths, dock/pier fragments,
  sunken temple tops, giant coral arches.
- Placed in `workspace.Map` (or a dedicated folder inside it) so depth rays see
  them.
- `Anchored = true`, `CanCollide = true`.
- Base below `PLANE_OFFSET` (draft), top above it. Avoid filling the whole
  interior; players should walk inside without instant collision.
- Structures can be **prebuilt template models** cloned from `ReplicatedStorage`
  or **primitive assemblies** (already popular pattern) — start with simple
  primitives so the system is reliable, then add fancier templates.
- Weight selection: structure rarity + only valid if it fits within the island's
  radius and (optionally) doesn't overlap other structures.

**9b. Unanchored floating objects (harder)**
- Examples: barrels, crates, buoys, rafts, debris.
- Recommended approach: **reuse `BoatManager.CalculateBuoyancy`**.
- Add 4 `Attachment`s to a root part, sample
  `HeightLookup.Lookup(x, z, "PRECISE"/"FAST", ...ZoneInfo)` at those points,
  and move the object toward the computed target Y + pitch/roll each heartbeat.
- Two sub-options:
  - **Anchored float simulation** (simplest, stable): anchored object whose
    CFrame is smoothly animated to wave height. Players can stand/walk on it and
    see it bob, but cannot push it.
  - **Unanchored buoyant object** (more physical): use `AlignPosition` +
    `AlignOrientation` / `VectorForce` + damping, driven by the same wave
    height. This is interactive but more fragile; tune damping heavily and
    prevent cheap physics explosions by keeping object light, massless above
    waterline, or pre-scaled.
- Prefer the anchored float version first. Add the truly physical version as a
  follow-up only if needed.
- Never let floating objects sync continuously over `RemoteEvent`; server owns
  the movement and replication streams automatically.

### 10. Performance strategy

- **Part count**: one `MeshPart` (+ 1–2 decor parts) per island is the target.
- **Generation queue**: process islands/structure in small batches with
  `task.wait()` between batches so the server never blocks.
- **Mesh reuse**: if using prebuilt structure templates, clone templates rather
  than reconstructing geometry each time.
- **Despawn/streaming**: if the world is large, despawn far islands/structures
  and rebuild deterministically when the player approaches.
- **Avoid loops over every vertex every frame**: bake height/colors once at
  generation time; only floating objects read wave height `Heartbeat`.
- **Limit floating objects** per island (e.g. 1–6) to keep physics cheap.

### 11. Determinism / seed

- `Settings.Seed` `IntValue` is the world seed.
- `Random.new(worldSeed + islandIndex)` for per-island category/shape/structures.
- Keep generation functions **pure** (same inputs → same outputs).
- If the generator uses `math.noise`, pass the seed explicitly rather than using
  global state.

### 12. Client / server responsibilities

- **Server** generates everything (meshes, structures, floating object state).
  It is authoritative.
- **Client** does not generate islands. It may receive lightweight data (e.g.
  for a map overlay or preview) if desired, but nothing gameplay-critical.
- No RemoteEvents needed for the core generator unless the client must request a
  preview. Keep generation server-only.
- Make generated instances replicate normally to each player (they will, as
  normal server-created instances).

### 13. Edge cases the next AI must handle

1. Existing world (user-placed anchors) + procedural spawn both active.
2. No `Radius` on an island model → use category default, fallback to bounding
   box.
3. Missing `Center` → skip island with a warning (do not crash).
4. Category weights all zero/omitted → default to equal weights.
5. Two islands overlapping → reject second placement from procedural mode, but
   keep user-placed anchors.
6. A structure doesn't fit the island radius → skip that structure, try next in
   weighted pool.
7. Floating object drifts out of range / collides with island → clamp or reset.
8. Island/character/asset generation fails (e.g. mesh creation fails) → warn and
   continue without killing the generator loop.
9. `PLANE_OFFSET` changes → islands/structures should read config height, not
   hardcode `25`.
10. Regenerating with the same seed → identical result.
11. World seed 0 → reseed like `Settings` already does.
12. Structures spawning inside players/boats → place with margin + query
    `workspace` for nearby parts (don't rely on client).
13. Player respawn / server restart with saved state (if any) — keep stateless
    generation initially.
14. Fluid performance: keep `Heartbeat` cycle short; do not run multiple
    expensive lookups per object per frame unless necessary.

### 14. Open questions (decisions for the next AI)

- **Finite vs infinite world?**
  - If finite: place all islands at boot via jittered grid / Poisson, with
    despawn/reload around the player.
  - If infinite: use chunk/cell hashing for deterministic streaming.
- **Structure templates: primitives or prebuilt Models?**
  - Recommend starting with primitives, then drop in fancier `Model` templates.
- **Biome choice: global vs per-island?**
  - Recommend per-island weighted selection by default; single-biome mode as a
    simple flag.
- **Radius semantics**: should generation use the exact `Radius` as the hard
  edge, or as a max with noise variance? Recommend exact edge = `Radius`,
  with noise-varied interior shape.
- **Floating object physics**: anchored-bob first + physical buoyancy as opt-in?

---

## Part 2 — Prompt for the Next AI

> You are implementing **island generation** for the existing **BRINE** Roblox
> ocean project in this repo. Do **not** rewrite the Gerstner ocean system,
> `ZoneManager`, `Helper`, `BoatManager`, or `Octree`. Read
> `src/ReplicatedStorage/Gerstner/Serial/ZoneManager/init.luau`,
> `src/ReplicatedStorage/Gerstner/Helper.luau`,
> `src/ReplicatedStorage/Gerstner/Serial/BoatManager.luau`, and
> `src/ReplicatedStorage/Gerstner/Settings/init.luau` first.
>
> ### Goal
>
> Build a simple, readable, deterministic, server-authoritative island
> generator that:
>
> 1. Uses the existing island contract expected by `ZoneManager`: an `Island`
>    `Model` with a `Center` `BasePart` (Size `1,1,1`, the `PrimaryPart`) and a
>    `Radius` `IntValue` set by the user. If radius is missing, fall back to a
>    category default, then to the model bounding box.
> 2. Generates **seamless, optimized** island terrain as few collidable
>    `MeshPart`s per island (target 1–3 parts), placed in `workspace.Map` and
>    tagged `"Island"` via `CollectionService` so `ZoneManager` indexes them.
> 3. Uses **EditableMesh → `AssetService:CreateMeshPartAsync`**.
> 4. Supports **biome categories and island type categories** with **rarity
>    weights**. Missing weight uses a `DEFAULT_WEIGHT` (recommend `1`). Pick
>    deterministically with `Random.new(worldSeed + islandIndex)`.
> 5. Generates **anchored, slightly submerged structures** (shipwrecks, ruins,
>    dock pieces, etc.) that appear partly above the water and are explorable.
>    Place them under `workspace.Map` so depth raycasts see them.
> 6. Generates **unanchored floating objects** (barrels, crates, buoys, debris)
>    that bob with the ocean. Use the existing `BoatManager.CalculateBuoyancy`
>    pattern and `HeightLookup.Lookup` to sample wave height; do not invent a
>    new wave system. Prefer a stable anchored-bob first; provide optional
>    physical buoyancy only if easy.
> 7. Does **not** depend on client input; server authoritative.
>
> ### Requirements
>
> - Extend the Rojo project under `default.project.json`. Add files under:
>   - `ReplicatedStorage.IslandGeneration.IslandConfig` (ModuleScript) — data
>     only.
>   - `ReplicatedStorage.IslandGeneration.IslandGenerator` (ModuleScript) —
>     noise, mesh-building, placement, weighted pick.
>   - `ServerScriptService.IslandGenerationServer` (Script) — orchestrator.
>   - Optional `ReplicatedStorage.IslandGeneration.IslandTypes` or structure
>     module only if it genuinely simplifies things.
> - The island surface should align to `Settings.GRID_SETTINGS.PLANE_OFFSET`
>   (default `25`), not hardcoded `0`.
> - Reuse `Math`/noise helpers already present where sensible. Do not create a
>   big framework.
>
> ### Config shape
>
> Provide an `IslandConfig` with, at minimum:
>
> - `DEFAULT_WEIGHT`
> - `PlaneOffset` (reads/mirrors `Settings.GRID_SETTINGS.PLANE_OFFSET`)
> - `BiomeCategories` (e.g. Jungle, Snow, Desert) with `Weight`, ground colors,
>   terrain style settings, structure pool/weights
> - `TypeCategories` (e.g. Islet, Atoll, Mainland) with `Weight`, `RadiusMin`,
>   `RadiusMax`, `MaxHeight`
> - `StructureDefinitions` with `Weight`, `Category`, `Mode` (`Anchored`/
>   `Floating`), draft/above-water offsets, `MinRadius`, `MaxRadius`
> - `Placement` options: spacing padding, world radius/cell size, max structures
>   per island, max floating objects
> - `Generation` options: mesh resolution, max islands per batch, LOD
>
> All values should be easy to tweak and documented in comments. If a category
> has no `Weight`, treat it as `DEFAULT_WEIGHT`.
>
> ### Implementation details
>
> **Island model creation**
> - For each island anchor, read `Center` and `Radius`.
> - Build a heightmap across the radius. Use a seeded `fBm`/`math.noise` plus a
>   radial falloff so the edge trends to water level.
> - Tint vertices by chosen biome and height/slope (sand near water, grass,
>   rock, snow, etc.).
> - Generate one `EditableMesh`, then create the `MeshPart` with
>   `AssetService:CreateMeshPartAsync(Content.fromObject(em), ...)`.
> - Parent the `MeshPart` to the island, set `Anchored = true`,
>   `CanCollide = true`, and keep `Radius`/`Center` intact.
> - Tag `"Island"` and parent under `workspace.Map`.
> - Keep generation batched (`task.spawn`/queue, small waits) so a large world
>   does not freeze the server.
>
> **Structures**
> - Weighted pick from the structure pool for the chosen biome/type.
> - Skip structures that don't fit `Radius` or overlap other structures/parts.
> - Anchored structures: anchored, CanCollide, partially below
>   `PlaneOffset`, mostly above, placed under `workspace.Map`.
> - Floating objects: create a small root part with 4 `Attachment` sample
>   points; each `Heartbeat` compute target Y + orientation with
>   `BoatManager.CalculateBuoyancy`/`HeightLookup.Lookup`, then apply.
> - Add a configurable `MaxFloatingObjectsPerIsland` and `MaxStructuresPerIsland`.
>
> **Placement**
> - Support user-placed anchors (drop in `Island` models with `Center` +
>   `Radius`). If none exist, support simple procedural placement via jittered
>   grid or Poisson/blue-noise with `Octree` overlap checks.
> - Minimum center distance = `radiusA + radiusB + padding`.
>
> **Determinism**
> - Derive all RNG from `Settings.Seed` and per-island index. Never call
>   `math.random()` directly. Same seed → same islands.
> - If `Settings.Seed == 0`, reseed like `Settings` already does.
>
> **Networking/security**
> - Everything is server-side. No RemoteEvent needed for core generation.
> - Never trust client positions/state for placement.
>
> **Edge cases to explicitly handle**
> 1. Missing `Center` / `Radius`. 2. All-zero or missing weights. 3. Overlapping
> procedural placements. 4. Structures that don't fit. 5. Floating objects
> colliding with islands/players. 6. Mesh creation/closing failures. 7.
> `PLANE_OFFSET` changes. 8. Regeneration determinism. 9. World seed `0`. 10.
> Large worlds without server freezes. 11. Structures spawning inside boats.
> 12. A player respawn/restart leaves no stale state.
>
> ### Deliverables
>
> Provide:
> - Exact Explorer hierarchy and Rojo disk paths.
> - Config module.
> - Generator module.
> - Server script.
> - Comments explaining each important decision.
> - How target/category/weight selection works.
> - How the mesh is built.
> - How anchored vs floating structures differ.
> - How placement/overlap checks work.
> - How every edge case is handled.
> - Any tuning knobs a user would want to change.
>
> Keep it simple, readable, practical, and avoid overengineering. Do not put
> large generated artifacts in Git; keep config/data in `IslandConfig`.
