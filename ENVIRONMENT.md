# BRINE — Environment, System Integration & Holistic Mental Model

> **Purpose.** This document explains **the environment** the code runs in, **how
> each system works**, **how they connect together**, and a **simplified mental
> model** that lets a new engineer (or a future AI) understand the whole thing
> quickly and safely. It is deliberately build-agnostic: it explains *what must
> exist at runtime* and *what each module contributes*, not just which files
> exist.
>
> This is a companion to [`AUDIT.md`](AUDIT.md) (findings/optimizations) and
> [`ROADMAP.md`](ROADMAP.md) (planned work). It contains **no code changes.**

---

## 1. What this project is

**BRINE** is a **Roblox / Rojo** project implementing a **Gerstner-wave ocean**.
The core idea of Gerstner waves is that the water surface is not just a vertical
bump — each surface point is displaced both **vertically** and **horizontally**
along the wave direction, which is what produces the rolling, choppy look of
real ocean rather than flat sinusoids.

On top of that core it layers:

- An **accurate height lookup** so floating objects (a ship) can sit on the
  water.
- **Island generation/streaming** that places premade island models into the
  world and feeds them back into the ocean's shore/depth logic.
- A **spatial index (Octree)** used to keep island/zone queries fast.
- A **hand-holding** R15 interaction system (unrelated to the ocean, but part of
  this repo).
- A developer **tooling** folder for linting/formatting and a model-preflight
  evaluation gate.

The code is split into **server-authoritative** logic and **shared** modules.
Everything is mirrored to disk via `default.project.json` (Rojo).

---

## 2. The DataModel environment

This is a Roblox **DataModel** (the runtime object tree). Rojo maps the filesystem
onto instances. Below are the real runtime containers and where the project's
instances live.

```
DataModel
├── ReplicatedStorage                       — shared, replicated to all clients
│   ├── Gerstner [Folder]
│   │   ├── init.luau                        → Gerstner (ModuleScript) — wave math
│   │   ├── Types.luau                       → Types (ModuleScript) — type defs
│   │   ├── Helper.luau                      → Helper (ModuleScript) — frustum / color / depth / UV / island&zone math
│   │   ├── HeightLookup.luau                → HeightLookup (ModuleScript) — water height query
│   │   ├── Appearance.model.json            → Appearance (SurfaceAppearance, grey, no PBR maps yet)
│   │   ├── Settings/
│   │   │   ├── init.luau                    → Settings (ModuleScript) — waves + all tuning constants
│   │   │   └── Seed.model.json              → Seed (IntValue, 0)
│   │   └── Serial/
│   │       ├── BoatManager.luau             → BoatManager — buoyancy math for 4-pt sampling
│   │       ├── Setup/
│   │       │   ├── init.luau                → Setup — builds EditableMesh, creates ocean plane(s), subdivision
│   │       │   └── ExistingMesh.model.json  → ExistingMesh (MeshPart)
│   │       └── ZoneManager/
│   │           ├── init.luau                → ZoneManager — island/zone spatial index + multipliers
│   │           ├── EditZone.model.json      → EditZone (RemoteEvent)
│   │           └── ZoneUpdated.model.json   → ZoneUpdated (BindableEvent)
│   ├── HandHolding [Folder]
│   │   ├── HandHoldingConfig.luau           → config (numbers, server/client shared)
│   │   └── HandHoldingEvent.model.json      → HandHoldingEvent (RemoteEvent)
│   ├── IslandGeneration [Folder]
│   │   ├── IslandConfig.luau                → island tuning (data-only)
│   │   └── IslandGenerator.luau             → island streaming/placement engine
│   └── Octree.luau                          → Octree (ModuleScript) — generic spatial structure
│
├── ServerScriptService                      — server-only logic
│   ├── HandHoldingServer.server.luau        → R15 hand-holding state machine
│   └── IslandGenerationServer.server.luau   → starts island streaming
│
├── StarterPlayer
│   └── StarterPlayerScripts
│       ├── HandHoldingClient.client.luau    → R15 hand-holding input/target picker
│       └── OceanParallel/                    → ocean renderer (ROADMAP 3.1–3.3)
│           ├── init.client.luau              → mesh setup, chunk dispatch, ClientInit
│           └── ParallelWorker.client.luau    → parallel Actor: per-chunk vertex update
│
├── Workspace
│   ├── singletons/Folder
│   │   └── Ship [Model]
│   │       ├── Handler.server.luau          → ship ownership + collision groups
│   │       └── Client.client.luau           → ship controls + buoyancy driver
│   └── (runtime-only, created/expected at runtime:)
│       ├── Ocean         [Folder]  — ocean planes parent here
│       ├── Map           [Folder]  — islands + depth-raycast target + ZoneManager scan
│       ├── GlobalWind    [Vector3Value] — BrownianMotionWaves reads `.Unit`
│       └── _RisingIslands [Folder] — islands mid-rise/sink
│
└── ServerStorage
    └── Islands [Folder]  — premade island templates (biome folders, any depth)
```

### 2.1 Disk → instance mapping rules

Rojo is filename-sensitive. Two rules are **load-bearing** (documented in
`README.md` and re-summarized here because they are easy to break):

- A **Folder with children** uses `init.luau` inside the folder (e.g.
  `Gerstner/Serial/Setup/init.luau` → `Setup` ModuleScript). You **cannot** use a
  bare `Foo.luau` plus a sibling `Foo/` dir — Rojo would emit two instances
  called `Foo`.
- `Serial` sits **inside** `Gerstner`, not beside it, because `Setup` resolves
  its sibling modules two levels up:
  `require(script.Parent.Parent.Types)` → `script.Parent.Parent` must be
  `Gerstner`.

---

## 3. External runtime dependencies (NOT created by this repo)

These must exist in the place for the ocean to work. They are **absent** from
`default.project.json` on purpose — they are authored in Studio or supplied by
the host.

| Dependency | Who reads it | What it must be | Consequence if missing |
| --- | --- | --- | --- |
| `workspace.Ocean` | `Setup` | Folder | Ocean planes have no parent → error when parenting `Plane.Parent = workspace.Ocean`. |
| `workspace.Map` | `Helper`, `ZoneManager`, `IslandGenerator`, Ship `Handler` | Folder (created by `IslandGenerationServer` if absent) | Depth raycasts find nothing; ZoneManager scans nothing; ship island-collision tagging no-ops. |
| `workspace.GlobalWind` | `Settings.BrownianMotionWaves` | Vector3Value/part with `.Unit` | If `BrownianMotionWaves` is enabled and this is missing, `.Unit` errors. (Currently the `BrownianMotionWaves` line is commented out; a hardcoded wave table is used instead.) |
| `ServerStorage.Islands` | `IslandGenerator` | Folder of biome folders containing island `Model`s | Generator warns and no-ops; no islands placed. |
| `Workspace.singletons.Ship` | Ship scripts | Model with `Main`, `VehicleSeat`, `Client`, and `Main.TopLeft/TopRight/BottomLeft/BottomRight` attachments | Ship fails to drive. |
| `ReplicatedStorage.Gerstner.Appearance` | `Setup` | `SurfaceAppearance` model (grey, no PBR maps). Synced to the live place. | Ocean planes have no PBR maps; `Setup` clones it onto every plane. |

> ⚠ **Two known gaps from `README.md`, confirmed by this audit:**
> `Appearance` is a placeholder (must be replaced with a `SurfaceAppearance`),
> and `EditZone` is declared a `BindableEvent` but used with `RemoteEvent` APIs
> (see [`AUDIT.md`](AUDIT.md) §7).

---

## 4. System-by-system: what each one does and contributes

### 4.1 Gerstner wave math — `Gerstner/init.luau`

**Contribution:** the *single source of truth* for the shape of the ocean.
Given a set of `WaveInfo` (direction, wavelength, steepness, gravity) and a
position + time, it returns the **displacement offset** of that point, optionally
with tangents/normals.

Public API:

| Function | Result | Cost | Used by |
| --- | --- | --- | --- |
| `new(Direction, WaveLength, Steepness, Gravity?)` | `WaveInfo` (precomputes `WaveNumber`, `WaveSpeed`, `WaveAmplitude`) | tiny | `Settings` |
| `ComputeTransform(Waves, Pos, t, ...)` | `Vector3` offset | O(waves) | `HeightLookup` (PRECISE/RAY path) |
| `ComputeWave(...)` | single wave offset | tiny | (internal) |
| `ComputeTransformAndNormal(...)` | offset + normal | O(waves), more math | intended for lighting/rendering (no in-repo caller) |
| `ComputeWaveAndNormals(...)` | offset + tangent + binormal | — | (internal) |
| `GetVortexTransform(...)` | offset + UV rotation for whirlpools | heavy (vector allocs) | `HeightLookup` (whirlpool zones) |
| `GetApproximateHeight(...)` | fast approximate Y | lighter than mesh lookup | `HeightLookup` (FAST) |
| `SET_SETTINGS(...)` | updates grid/UV globals | — | **no in-repo caller** (see audit) |

**Contribution to the whole:** everything that needs to know where the water is
ultimately calls back into this module's math.

### 4.2 Settings — `Gerstner/Settings/init.luau` (+ `Seed`)

**Contribution:** the *tuning surface* and the *world seed*.

- Defines the wave set (`Waves`) — currently 3 hardcoded waves, with a
  `BrownianMotionWaves()` generator available (commented out).
- Defines grid settings (chunk size, padding, plane offset, UV scale), render
  distances, LOD subdivisions, island multipliers, wave colors, UV scroll, depth
  ray length/offset, whitecap height, shore transparency, and the
  `FRUSTUM_CULLING_FIX` flag.
- **Seed handling:** if `Seed.Value == 0`, it reseeds to a random value and
  writes it back. This makes the world deterministic across restarts once a seed
  is set. `IslandGenerator` reuses this same `Seed` IntValue so ocean and islands
  share one seed.

### 4.3 Helper — `Gerstner/Helper.luau`

**Contribution:** the *ocean look & interaction* helpers and the *zone/island
multiplier* math.

- **Frustum culling primitives** (`GetFrustumPlanes`, `IsInView`,
  `IsChunkInView`) — intended to skip off-screen ocean chunks. **No in-repo
  caller** (a renderer would use these).
- **Vertex color** (`GetVertexColor`) — maps wave height to crest/trough colors,
  blends to shore color near islands, adds whitecaps above `WHITECAP_HEIGHT`,
  and tints for whirlpools.
- **Vertex transparency / shore depth** (`GetVertexTransparency`,
  `IsVertexNearShore`) — raycasts down into `workspace.Map` to detect shallow
  water near islands; returns transparency. Caches results in a `SharedTable`
  keyed by a hashed XZ.
- **UV scroll** (`GetUV`) — scrolls the ocean texture over time.
- **Geometric helpers** (`Lerp`, `PointInEllipse`, `ScaledDistance`).
- **Island/zone multipliers** (`GetIslandMultipliers`, `GetZoneMultipliers`) —
  the numbers that make waves flatten/slow near islands and change inside zones
  (whirlpools, etc.).
- **`HashVector`** — packs an XZ into a 32-bit int for the transparency cache.

**Contribution to the whole:** transforms pure wave math into *visuals* and
*tuned behavior* near features.

### 4.4 HeightLookup — `Gerstner/HeightLookup.luau`

**Contribution:** answers the recurring question **"what is the water height at
this XZ?"** with three accuracy/speed tiers:

| Method | How | Cost | Typical use |
| --- | --- | --- | --- |
| `PRECISE` | resolve the 3×3 grid cell around the point, apply Gerstner offsets to the 6 local triangles, barycentric-interpolate the vertical height | high (24 search regions × 8 triangles × ~4 area calls) | accurate boat sampling |
| `PRECISE_RAY` | `EditableMesh:RaycastLocal` straight down | very high (~0.7 ms; builds a KD tree each call) | client-only, when you have the mesh |
| `FAST` | `GetApproximateHeight` analytic approximation | low | cheap far-away sampling |

**Contribution to the whole:** this is the *interface* between the analytic waves
and anything that floats. Boxy: the ship's buoyancy calls it 4×/frame with
`PRECISE`.

On the client it requires `ClientInit(...)` to have been called (which sets
`_PLANE`/`EditableMesh`). The ocean renderer calls it once the mesh exists
(`StarterPlayerScripts/OceanParallel/init.client.luau`, ROADMAP 3.2). The ship no
longer uses `PRECISE` at all (ROADMAP 2.4), so this matters only for other callers.

### 4.5 Setup — `Gerstner/Serial/Setup/init.luau`

**Contribution:** *builds the physical ocean geometry.*

- `SetupEditableMesh()` — generates a grid of vertices/triangles into an
  `EditableMesh` (fixed size), records per-vertex metadata (`VertexInfo`, a
  `VertexPositionToId` map, and `_QUADS`/`_TRIANGLES`).
- `GetPlaneFromEditableMesh(...)` — turns the `EditableMesh` into a `MeshPart`,
  applies `ExistingMesh`, sets `CanCollide=false`, material, and parents it into
  `workspace.Ocean`. Also clones `Gerstner.Appearance` onto it (the placeholder).
- `SubdividePlane(...)` — adaptive subdivision creating more detail near the
  center of the mesh (LOD), with border stitching for neighboring quads.
- `SetupSecondaryPlanes(...)` — creates 8 identical planes around the main one to
  tile a large ocean surface.

**Contribution to the whole:** translates math into an actual visual/collidable
mesh, and builds the LOD structure other systems rely on.

These functions are driven by the ocean renderer, `StarterPlayerScripts/OceanParallel/`
(client LocalScript, with `ParallelWorker.client.luau` as its child Actor script).
It was live-only before Phase 3 and is now in the repo.

### 4.6 Octree — `ReplicatedStorage/Octree.luau`

**Contribution:** a generic, dependency-free **spatial index** (a hierarchical
spatial hash of cubes). Used by `ZoneManager` and `IslandGenerator` to answer
"what is near here?" without scanning every object.

- `new()`, `CreateNode`, `RemoveNode`, `ChangeNodePosition`,
  `SearchRadius`, `ForEachInRadius`, `GetNearest`, `GetAllNodes`,
  `FindFirstNode`, `CountNodes`, `ClearAllNodes`.
- Regions are cubes that recursively subdivide up to `MAX_SUB_REGIONS` (4);
  leaf regions hold arrays of `Node<T>`.

**Contribution to the whole:** the reason zone/island lookups are cheap enough to
run per-frame/per-placement.

### 4.7 ZoneManager — `Gerstner/Serial/ZoneManager/init.luau`

**Contribution:** bridges **islands** and **dynamic zones** into the wave math.

- Maintains two octrees: `ISLAND_TREE` (for islands, from `workspace.Map` or
  `CollectionService` "Island" tag) and `ZONE_TREE` (for runtime zones like
  whirlpools).
- `InsertZone`, `RemoveZone`, `UpdateAllNodes` — mutate the zone tree.
- `GetZoneParameters(pos)` → the overlapping zone/island data (prioritizing
  zones over islands).
- `GetZoneMultipliers` / `GetIslandMultipliers` — delegate to `Helper`.
- Maintains island lifecycle via `CollectionService` tag signals + `Destroying`
  connections, and `Map` folder child events.
- **Client/server split:** on the server it broadcasts zone inserts over
  `EditZone:FireAllClients`; on the client it listens on `EditZone.OnClientEvent`.
  Both should be a `RemoteEvent`, not a `BindableEvent` (see audit).
- `ZoneUpdated` (a `BindableEvent`.Event) signals clients to refresh multipliers.

**Contribution to the whole:** makes waves behave differently near islands and
inside special zones, and tells the ship which multipliers to apply.

### 4.8 BoatManager + Ship — buoyancy & control

**`BoatManager.CalculateBuoyancy`** takes 4 attachment sample points around a
boat, reads the water height at each (via `HeightLookup.Lookup`), and returns:

- a target **Y** (vertical position),
- an **orientation** (pitch/roll from front/back and left/right height
  differences),
- a **clamped depth** (how submerged it is, used to scale the mover force).

**`Ship/Client.client.luau`** (runs on the client) owns the driving:

- Creates modern movers (`AlignPosition`, `AlignOrientation`, `LinearVelocity`)
  parented to a `moverAttachment` on the `VehicleSeat`.
- Each `PostSimulation`: reads steer/throttle, computes `CalculateBuoyancy`,
  applies the position/orientation/velocity.
- Queries `ZoneManager` for zone/island multipliers every ~3 s.
- Drives a smooth `currentRotation` for steering.

**`Ship/Handler.server.luau`** (runs on the server):

- Sets the seat's network owner to nil, then grants ownership to the occupant.
- Clones the `Client` LocalScript into the occupant's `PlayerGui` (so the driver
  only sees it).
- Registers collision groups `Ship` / `ShipIsland`, marks `workspace.Map`
  descendants as `ShipIsland`, and disables `Ship`↔`ShipIsland` collision so the
  boat cannot climb islands.

**Contribution to the whole:** turns water height into a functioning, driveable
floating boat that respects islands.

### 4.9 Island generation — `IslandGeneration/*`

**`IslandConfig`** — data-only tuning: placement/streaming/rising/despawn
parameters, biome weights, the premade-island root, and `PlaneOffset` (mirrored
from ocean settings).

**`IslandGenerator`** — the streaming engine:

- Discovers premade island `Model`s under `ServerStorage.Islands` (recursing
  through folders, not into Models).
- Deterministic per-world-cell placement: hashes `(worldSeed, cellX, cellZ)` to a
  seeded RNG, jitters a grid position, checks overlap via octree + broadphase
  obstacle query, and caches a lightweight record (no instance).
- A background loop opportunistically generates/activates cells around moving
  players, bounded by `MaxCellsPerCycle`/`CellsPerYield`/
  `MaxActivationsPerCycle`/`MaxActivationsPerCycle`.
- Activation clones the template into `workspace._RisingIslands`, tweens it
  upward, then publishes it into `workspace.Map` tagged `"Island"`.
- Enforces a `MaxRenderedIslands` cap, culling the farthest/oldest when full
  (culls are cached; lifetime despawns are permanent).
- Public API: `Generate`, `PlaceOne`, `GetCatalog`, `GetStats`, `ClearGenerated`.

**`IslandGenerationServer`** — thin orchestrator; ensures `workspace.Map` exists
and calls `Generate()` in a spawned thread.

**Contribution to the whole:** populates the world with islands, which then flow
back into `ZoneManager` (for wave multipliers) and `Helper` (for shore/depth
coloring and transparency).

### 4.10 Hand-holding — `HandHolding/*`

A **server-authoritative** R15 interaction using `IKControl` + `VectorForce`,
independent of the ocean.

- **`HandHoldingConfig`** — shared numbers (distance, cone angle, offer timeout,
  IK/spring tuning).
- **`HandHoldingClient`** — toggles on `L` (not a hold), picks a facing-cone
  target, fires `("PressL", target)` / `("ReleaseL")`.
- **`HandHoldingServer`** — validates everything (R15, range, not busy), runs the
  offer→accept state machine, creates IK + equal/opposite horizontal spring
  forces, validates each heartbeat, and cleans up on release/death/leave.

**Contribution to the whole:** a self-contained social feature; it shares only the
`players`/`replication` environment, not the ocean.

### 4.11 Tools — `tools/`

- `check-syntax.js` — lightweight Luau syntax check via `luaparse` (strips Luau
  type syntax first).
- `evaluate-models.js` + example model/suite — a fail-closed preflight LLM gate;
  it evaluates candidate model adapters without exposing the production prompt.
- `setup-tools.sh`, `stylua.toml`, `selene.toml` — toolchain bootstrap + linter
  configs.

**Contribution to the whole:** reproducibility and safe model admission.

---

## 5. How the systems connect (data flow)

The central question everything orbits is **"where is the water surface?"**

```
               ┌──────────────────────────────────────────────┐
               │                 Settings                     │
               │  (waves, grid, colors, seed IntValue)        │
               └──────┬──────────────────────────┬────────────┘
                      │ WaveInfo set             │ Seed (world seed)
                      ▼                          ▼
   ┌────────────────────────┐          ┌──────────────────────┐
   │  Gerstner (wave math)  │          │ IslandGenerator      │
   │  new / Compute* /      │          │ (discover + place)   │
   │  GetVortex / Approx    │          └──────────┬───────────┘
   └──────────▲─────────────┘                     │ clones islands
              │ ComputeTransform                  ▼
              │                             workspace.Map [Folder]
   ┌──────────┴─────────────┐                     │ + "Island" tag
   │  HeightLookup.Lookup   │◄───── 4×/frame ─────┤
   │  PRECISE / RAY / FAST  │                     │
   └──────────▲─────────────┘                     ▼
              │ height per point         ZoneManager (ISLAND_TREE / ZONE_TREE)
              │                                  │ ApplyIslandMultipliers / GetZoneMultipliers
              │                                  │      │
   ┌──────────┴─────────────┐                    │      │
   │  BoatManager / Ship    │◄───────────────────┘      │
   │  CalculateBuoyancy     │  (multipliers + heights)  │
   └────────────────────────┘                           ▼
                                              Helper (color/transparency,
                                              depth raycast, UV scroll,
                                              frustum, HashVector)
```

### 5.1 The three "heights" and who uses which

| Height notion | Module | When used |
| --- | --- | --- |
| **Analytic wave height** | `Gerstner.GetApproximateHeight` | cheap visual + `FAST` lookups |
| **Mesh-accurate height** | `HeightLookup` (`PRECISE`/`PRECISE_RAY`) | ship buoyancy; needs mesh on client |
| **Visual surface** | `Helper` (color/transparency) | shoreline/foam/whirlpool look |

### 5.2 The two "spatial" systems

| Structure | Holds | Answer |
| --- | --- | --- |
| `Octree` (generic) | any `Node<T>` | "what's near X?" |
| `ZoneManager` (2 octrees) | islands + zones | "what zone/island is this point in, and what multipliers apply?" |

### 5.3 Shared state & replication

- **No RemoteEvents needed** for the ocean (it's modular math/modules). The only
  RemoteEvent in the repo is `HandHoldingEvent`.
- `EditZone` is a RemoteEvent (fixed, AUDIT B-1).
- Islands are server-owned and replicate as normal instances; clients never
  generate them.
- The ship client is spawned server-side into the driver's `PlayerGui` and given
  network ownership.

---

## 6. Simplified mental model (the “holistic future” version)

To make this easy for a future engineer/AI, reduce the whole repo to **five
abstractions** and **one question**:

> **THE QUESTION:** *"Given a world position and time, what is the water doing,
> and what should the water look like / how should things float?"*

1. **Waves** = a pure function from `(position, time, waveSet) → offset`. That's
   `Gerstner`. No world state.
2. **Surface** = the mesh that makes waves visible. That's `Setup`
   (EditableMesh → planes) + `HeightLookup` (query the mesh) + `Helper`
   (color/depth/UV). Together they answer "what does the surface look like and
   what's its exact height."
3. **Features** = islands and zones. `IslandGenerator` puts islands in the world;
   `Octree` + `ZoneManager` index them and *perturb* the wave multipliers so
   waves flatten near land and swirl in zones.
4. **Interaction** = `BoatManager` + the ship (float on the surface), and the
   separate `HandHolding` R15 feature.
5. **Environment** = Settings/seed + the external containers (`Ocean`, `Map`,
   `GlobalWind`, `Islands`) + tooling.

**The key insight for onboarding:** the repo is **a modular component library for
an ocean**, not a single self-driving script. The **ocean renderer/orchestrator**
is `StarterPlayerScripts/OceanParallel/`. It calls `Setup`, `HeightLookup.ClientInit`,
`GetFrustumPlanes`, `IsInView`, `GetVertexColor`, `ComputeTransformAndNormal`, and
`SET_SETTINGS`. It was live-only until Phase 3 sync.

### 6.1 One-sentence per system (handy cheat-sheet)

| System | One sentence |
| --- | --- |
| `Gerstner` | Computes wave displacement/normals/approx-height from wave parameters. |
| `Settings` | Holds the waves, grid, seed, and every tunable knob. |
| `Helper` | Turns heights into colors/transparency, scrolls UVs, culls frustums, computes island/zone multipliers. |
| `HeightLookup` | Answers "exact/approx water height here" for floaters. |
| `Setup` | Builds the ocean mesh, LOD subdivisions, and secondary tiled planes. |
| `Octree` | Generic spatial index for fast "what's near". |
| `ZoneManager` | Indexes islands/zones and reports their wave multipliers. |
| `BoatManager` | Samples 4 points to get a boat's target Y + pitch/roll. |
| `Ship` | Drives the boat (Client) and owns ownership/collision (Server). |
| `IslandGenerator` | Streams premade islands into `workspace.Map`, capped and cached. |
| `HandHolding` | Server-authoritative R15 hand-holding with IK + soft pull. |

---

## 7. Environment quirks & gotchas (read before touching anything)

1. **`Setup` requires `workspace.Ocean`** — parenting planes errors if it's
   absent.
2. **`Helper` raycasts into `workspace.Map` for depth/shore** — islands must live
   there for shore coloring/transparency to work.
3. **Shared `_settings` is required at module-load time** in several modules; the
   `Seed` IntValue must be present and (if 0) gets reseeded.
4. **`PlaneOffset` (default 25)** is the waterline; island geometry must be
   built relative to `25`, not `0`. `IslandConfig.PlaneOffset` mirrors this.
5. **Editor vs runtime split** — the modules assume an external driver exists
   (`ClientInit`, `SET_SETTINGS`, `Setup*`, frustum helpers). Don't assume they
   are "already running."
6. **Rojo naming rules** — never mix `Foo.luau` + `Foo/`; Folder-with-children
   uses `init.luau`.
7. **`EditZone` is a RemoteEvent** (`EditZone.model.json`). It was mislabeled as a
   BindableEvent until AUDIT B-1 was fixed; keep it a RemoteEvent.
8. **`Appearance` placeholder** — `Setup` clones it onto every plane but it's
   currently a ModuleScript `{}` with a `warn`. Replace with a real
   `SurfaceAppearance`.

---

## 8. References

- `README.md` — hierarchy + Rojo mapping + known gaps.
- `AUDIT.md` — full findings, bugs, optimization analysis.
- `ROADMAP.md` — improvement plan by system + priority.
- `BOAT_HANDLER.md` / `HAND_HOLDING.md` / `ISLAND_GENERATION.md` — per-system
  deep dives.
- Official Roblox docs links are embedded in the source comments and those `.md`
  files.
