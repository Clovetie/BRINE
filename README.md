# BRINE

Gerstner-wave ocean system by [@FlameEmber06](https://devforum.roblox.com/u/flameember06).

The repo is a [Rojo](https://rojo.space) project. Everything lives under
`ReplicatedStorage`, matching the hierarchy the scripts expect at runtime.

## Hierarchy

```
ReplicatedStorage
├── Gerstner [MS]
│   ├── Serial [FL]
│   │   ├── BoatManager [MS]
│   │   ├── Setup [MS]
│   │   │   └── ExistingMesh [MP]
│   │   └── ZoneManager [MS]
│   │       ├── EditZone [BE]
│   │       └── ZoneUpdated [BE]
│   │
│   ├── Appearance [MS]
│   ├── HeightLookup [MS]
│   ├── Helper [MS]
│   ├── Settings [MS]
│   │   └── Seed [IV]
│   └── Types [MS]
│
└── Octree [MS]
```

`Octree` is a direct child of `ReplicatedStorage`, not of `Gerstner` — both
`BoatManager` and `ZoneManager` resolve it with `require(RS:WaitForChild('Octree'))`.

## Layout on disk

Rojo maps the filesystem onto instances, so a few placements are load-bearing:

| Path | Instance |
| --- | --- |
| `src/ReplicatedStorage/Octree.luau` | `ReplicatedStorage.Octree` (ModuleScript) |
| `src/ReplicatedStorage/Gerstner/init.luau` | `ReplicatedStorage.Gerstner` (ModuleScript) |
| `src/ReplicatedStorage/Gerstner/Serial/` | `Gerstner.Serial` (Folder — no `init.luau`, so it stays a Folder) |
| `…/Serial/Setup/init.luau` | `Setup` (ModuleScript) |
| `…/Serial/Setup/ExistingMesh.model.json` | `Setup.ExistingMesh` (MeshPart) |
| `…/Serial/ZoneManager/init.luau` | `ZoneManager` (ModuleScript) |
| `…/Serial/ZoneManager/EditZone.model.json` | `ZoneManager.EditZone` (BindableEvent) |
| `…/Serial/ZoneManager/ZoneUpdated.model.json` | `ZoneManager.ZoneUpdated` (BindableEvent) |
| `…/Gerstner/Settings/init.luau` | `Settings` (ModuleScript) |
| `…/Gerstner/Settings/Seed.model.json` | `Settings.Seed` (IntValue, starts at 0) |

Anything that has children uses `init.luau` inside a folder rather than a
bare `Foo.luau` file: Rojo does **not** attach a sibling `Foo/` directory to
a `Foo.luau` script — it would emit two separate instances called `Foo`.

`Serial` sits inside `Gerstner` (not beside it) because `Setup` resolves its
siblings two levels up:

```lua
local Types    = require(script.Parent.Parent.Types)
local _settings = require(script.Parent.Parent.Settings)
```

`script.Parent.Parent` has to be `Gerstner` for those to resolve, which is
also where `HeightLookup` (`require(script.Parent.Settings)`) and `Helper`
expect `Settings` to live.

## Building

```sh
rojo build -o brine.rbxlx     # standalone place
rojo serve                    # live sync into an open place
```

## Fix applied to the imported source

`Gerstner` and `HeightLookup` both opened with:

```lua
local v3.new = Vector3.new
```

## Also in this repo

`src/` also contains a small R15 hand-holding system under
`ReplicatedStorage/HandHolding`, `ServerScriptService`, and
`StarterPlayerScripts`. It uses a server-side `BallSocketConstraint` for a
real pullable connection and `L` is a toggle. See
[`HAND_HOLDING.md`](HAND_HOLDING.md) for the full hierarchy, protocol, and
edge-case walkthrough.

The boat singleton is mapped to `Workspace.singletons.Ship`, with its
`Handler` and `Client` scripts alongside the ship model. It uses modern mover
constraints and a ship/island collision-group fix so it cannot climb onto
islands. Reusable Luau syntax/lint tooling lives in [`tools/`](tools/README.md).

That is not valid Luau — the compiler rejects it with
`Expected identifier when parsing expression, got '.'`. Every call site uses
`v3.new(...)` / `v2.new(...)`, so the aliases were renamed to match the
naming already used by `v3zero` / `v2zero` / `v2new`:

```lua
local v3new = Vector3.new
local v2new = Vector2.new
```

Call sites became `v3new(...)` / `v2new(...)`. The `v1` / `v2` / `v3`
triangle-vertex locals in `HeightLookup` are untouched.

## Known gaps

These are the scripts' runtime dependencies that are *not* part of the
hierarchy above and are not created by this project:

- `workspace.Ocean` — `Setup` parents every plane here.
- `workspace.Map` — `Helper` raycasts against it for depth; `ZoneManager`
  scans it for islands.
- `workspace.GlobalWind` — a `Vector3Value`/part read by
  `Settings.BrownianMotionWaves`.
- `ServerStorage.Islands` — the premade island templates (biome folders, any
  nesting) the island generator clones into `workspace.Map`. See
  [`ISLAND_GENERATION.md`](ISLAND_GENERATION.md).
- Islands must be `Model`s tagged `Island` with a `Center` part (and an
  optional `Radius` IntValue) for `ZoneManager` to pick them up.
- `ServerStorage.FloatingObjects` — the unanchored floating-structure
  templates (`Model`s or single `BasePart`s, any folder nesting, tagged
  `Small`/`Medium`/`Large`/`Debris`) the floating-object generator streams
  into `workspace._FloatingObjects` under a hard 500-object render cap. See
  [`FLOATING_OBJECTS.md`](FLOATING_OBJECTS.md).

Two further things are worth deciding before this runs:

1. **`Appearance` is a placeholder.** Its source wasn't supplied. `Setup`
   clones it onto each plane as a mesh material, so it is expected to be a
   `SurfaceAppearance` — but the hierarchy tags it `[MS]`, so it was
   imported as a ModuleScript.
2. **`EditZone` is a BindableEvent per the hierarchy, but the code uses
   RemoteEvent APIs.** `ZoneManager` calls
   `script.EditZone:FireAllClients(...)` and
   `script.EditZone.OnClientEvent:Connect(...)`, neither of which exists on a
   BindableEvent. `ZoneUpdated` is correctly a BindableEvent — it only uses
   `:Fire()` and `.Event`. Changing `EditZone` to a RemoteEvent is a one-word
   edit in `EditZone.model.json`.
