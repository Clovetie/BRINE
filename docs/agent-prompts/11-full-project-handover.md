# Prompt for the next agent: edit, fix and polish the whole of BRINE

You are taking over a Roblox game called **BRINE** (an open-ocean survival/fishing sandbox) from an agent
that has just finished a nine-prompt audit. This document is your whole brief. Read it once, end to end,
before you touch anything. It tells you what the game is, what was already fixed, **what was measured and
must not be re-measured**, what is still broken, the rules the user has stated that you may not break, and
the order to work in.

You are expected to *edit the project*: fix the open defects, finish the polish pass, and leave the place
in a state where every claim you make is backed by a number you took or a file you read.

---

## 0. Ground rules that override everything else

1. **Never push to `main`.** All work goes on the branch `arena/ocean-sound-and-audit` (PR #9).
2. **Do not break these, they are user decisions, not bugs:**
   - `ServerBoat` is the physics *reference* hull. Do not change it or its script.
   - The fishing grab stays on a `DragDetector`. Never `AlignPosition`/`AlignOrientation` for the rod.
     (Ships and swimming legitimately use movers; that rule is fishing-only.)
   - Do not delete `Workspace.Part` (the platform slab, 121×230×98, anchored, top face Y = 70.24).
   - No overhang-sink code for unsupported platforms; the user will make platforms solid.
   - Floating objects must never despawn, cull or expire while in a player's sight.
   - No ocean **texture** work (no new SurfaceAppearance, no image assets). UV *mapping* bugs are fair game.
   - Do not change the wave design numbers (`58/41/30/25` wavelengths, `.26/.20/.14/.09` steepness)
     without asking.
   - Do not hide a symptom with fog, lowered amplitude, or a shortened view distance.
   - **No ship has a sail.** `Sail`-related code paths are dead for the playable fleet. Do not add one.
   - Each hull needs its **own** movement/steering settings; no shared uniform config.
   - `Hirabelan` is a real player, not a test rig.
3. **Studio is authoritative for taste/tuning values** where the repo and the place disagree.
4. **Never write a token into a file, a commit, a log or a prompt.** Pass it as a single command
   argument. Before every commit, grep the tree for the `github_pat` prefix and for the bridge token's
   first 8 characters; both must return nothing but documentation placeholders.
5. **Measure where the thing is, on the path the user is on, before you claim anything.** Every commit in
   this branch that fixed a real bug contains a number in its message. Keep that standard. If you could
   not measure it, write "unmeasured" in the commit and say so in the report.

---

## 1. Rebuilding the working environment (do this first)

You will probably start in a fresh sandbox containing only the repo (or not even that).

1. **Clone the PR branch, not `main`** (token supplied by the user, never committed):
   ```
   git clone -b arena/ocean-sound-and-audit "https://x-access-token:<TOKEN>@github.com/Clovetie/BRINE.git" /home/user/BRINE
   cd /home/user/BRINE && git config user.name "Arena Agent" && git config user.email "agent@arena.ai"
   ```
2. **Toolchain.** `.tools/` is gitignored. Run `bash tools/setup-tools.sh` (pins Luau 0.736, styLua
   2.5.2, selene 0.31.0) and `npm ci` in `tools/`. This matters: without `.tools/bin/luau-compile`,
   `tools/check-syntax.js` falls back to `luaparse` and reports **3 false failures**
   (`SwimClient`, `AmbientSea`, `ParallelWorker`). They are valid Luau. That is defect D-16; do not "fix"
   them. If `.tools/bin/*` lose the exec bit after a snapshot restore, `chmod +x` them or every file
   fails with `EACCES`.
3. **The Studio bridge** (if you will measure live, which you should). Two local-only files, never
   committed: `/home/user/.mcp/call.py` (JSON-RPC over the tunnel, `Authorization: Bearer <bridge
   token>`, handles `Mcp-Session-Id` and `text/event-stream`, `MCP_MAX` ~5 MB because `survey_place`
   returns ~950 KB) and `/home/user/probes/mcp_init.py` (starts a session, writes `/tmp/mcp_sid`).
   Usage: `python3 .mcp/call.py <tool> '<json>'`; the workhorse is `probe` with
   `{"dm":"server"|"client"|"edit","timeout":45,"code":"..."}`. Helper:
   `/tmp/runprobe.py <file.lua> <dm>` wraps a file in `pcall` and prints the returned string.
4. **Sanity check the repo before you change anything:**
   ```
   node tools/check-syntax.js      # expect 24/24
   node tools/smoke-test.js        # expect 97 passed, 0 failed, 5 warn
   node tools/validate-project.js  # expect 0 errors
   python3 tools/studio-probes/bridge/parity_hash.py /tmp/survey.json   # expect 41/41
   ```
   For the parity dump (note the extraction step; the raw tool output is a JSON-RPC envelope):
   ```
   MCP_MAX=8000000 python3 .mcp/call.py survey_place '{"includeSource":true}' > /tmp/s.json
   python3 -c "import json;d=json.load(open('/tmp/s.json'));json.dump(json.loads(d['result']['content'][0]['text']),open('/tmp/survey.json','w'))"
   python3 tools/studio-probes/bridge/parity_hash.py /tmp/survey.json
   ```

## 2. What the project is, physically

- **Rojo project** `default.project.json` maps `src/` to ReplicatedStorage, ServerScriptService,
  StarterPlayer/StarterPlayerScripts, StarterPack (the fishing tool) and `Workspace.singletons.Ship`.
- **`Workspace.singletons` does not exist in the place.** Each hull (`WoodenShip`, `MisoSoup`,
  `Boathouse`) carries its **own** `Handler` and `Client` copy of the ship scripts. A change to "the
  singleton" must be pushed three times, and each hull can silently drift. That was D-01. Push with
  `python3 tools/studio-probes/bridge/push_src.py <parent> <name> <className> <repo-relative-path>` and
  always read the hash back.
- **Ocean** is a client-built EditableMesh (`StarterPlayerScripts/OceanParallel`) with 6 parallel
  workers, a main 1872×1872 plane (3301 vertices, 48-stud padding, subdivided to 12 studs inside 400
  studs) and 8 far tiles. Per-hull tuning lives as **attributes on the models**, which Rojo cannot carry:
  `python3 tools/studio-probes/ships/apply_ship_attributes.py --check` is the source of truth.
- **Floating objects** are generated server-side (`FloatingObjectGenerator`), rendered client-side,
  frozen beyond a per-record `SimDistance`, and float via `WaveFloat.Solve`.
- **Fishing** is a `Tool` in StarterPack with its own config, remotes, retention budget and a
  `DragDetector` grab.
- **Sound** is `AmbientSea` on the client with 12 tracks driven by depth, sea state and time of day.

## 3. The state you inherit — verified, do not re-measure

Everything below was measured on this branch. Re-running it wastes a session; if you must re-check it,
check it *once* and note why.

### Repo health
`syntax 24/24`, `smoke 97/0` (5 warns), `validate 0/0`, `parity_hash 41/41` over 81 surveyed scripts,
tree clean, 32 commits on the branch (last: `ca21671`).

### The ocean surface (`docs/audit/02/03/04/10`)
- **The wave field never folds.** Finite differences on the real `ComputeTransform`: 0 folds in 73 205
  samples at calm, rough, the live sea-state field, ×1.5 and ×2.0 amplitude, and inside the
  `RoughSeaArea` zone (whose amplitude ×2.5 puts Σ steepness at 1.725, past the classic ≤ 1 rule).
  Only a uniform ×2.5 produced 1 grazing fold. **If waves look like they cross, it is not the height
  function** — it is LOD, colour, or the flat horizon plate (see D-29).
- **Physics reads the drawn surface**: `WaveFloat.HeightAt` inverts the Gerstner displacement; rest-vs-
  displaced p99 **1.2986 → 0.0094** studs, live engine check 0.0010.
- **Write cost** is linear in writes at **0.82 µs per position write**; a UV write measured **~5.7 µs**
  (one session each — a lead, not a result). The parallel section is ~3× the serial one and does not
  scale with the budget, so the budget never saved compute, only upload.
- **`WaveFloat.HeightAt` costs 4.00×** the old code at `INVERSE_STEPS = 3` (7.5 µs/call headless, plain
  Luau VM, not Roblox). `INVERSE_STEPS = 2` still passes the 0.1-stud budget (p99 0.0343) at 2.98×.
- **The colour ramp is fixed** (D-27): it was sized for a sea three times this one, so the whole mesh
  rendered *below* the TROUGH colour (mean blend −0.131) and CREST was never drawn. Now normalised by
  the wave set's envelope (Σ amplitudes = 4.7317 studs) and clamped: span 0.000…1.000, live bands
  0.50/0.47/0.49. `bash tools/measure/colour-ramp.sh` reprints before/after.
- **The 8 far tiles are fixed** (D-28): they mapped the texture at half the main plane's density and
  59.5 UV units out of phase at the seam; now the same mapping, a whole 78-unit offset.
- **Whitecaps cannot fire**: `WHITECAP_HEIGHT = 6` studs against an envelope of 4.7317, measured max
  2.92. The branch is commented as unreachable. Turning them on is a **look decision**, not a bug fix.

### Ships (`docs/audit/07-ships.md`)
- **The bounce is fixed and must be re-verified before it is claimed again.** It came back three times
  because it was measured on the wrong path. Settled `Main.Center` offsets after the fix: `WoodenShip`
  +0.88, `MisoSoup` +0.48, `Boathouse` +0.73 (before: `WoodenShip` sat at −4.00 with its deck 2.3 studs
  under water). Per-hull handling live: tops **26.0 / 18.0 / 13.9** studs/s, turn radii **113 / 163 /
  58** against the reference's 29.1 / 58.2.
- The force law is `lift = submerge * mass * (g + KP·errY − KD·(vNow.Y − surfaceVy))`; a model of it
  settles at 60, 45, 30, 24, 20, 15 and 10 Hz, and a server starved to 18 Hz gave **0 reversals**, so
  frame rate was never the cause. Gains were re-tuned twice and made it worse — do not retune them.
- `Handler` now guards its initial `SetNetworkOwner(nil)` in a `pcall` and runs a twice-a-second
  **authority watchdog** publishing `AuthorityOwner` / `AuthorityRepairs`. `StarterPlayerScripts/
  ShipBounceWatch` is a live diagnostic: it samples the nearest hull's **rendered** position (low-passed,
  `SWING = 0.08` studs) and prints one `[BRINE]` line only if it reverses 6+ times in 4 s. Validated:
  calm → silent; forced 15 Hz oscillation → 26 reversals, peak 25.1 studs/s.
- **`ServerBoat` rides 12.4 studs above the water.** That is its hover and it is out of bounds — but the
  hull is protected, so record it, do not fix it.
- Boathouse is **not** a broken ship: it is parked on `Workspace.Part`.

### Floating objects (`docs/audit/08-floating.md`)
- The system did not run at all until `5230580` (the server script threw before calling `Generate()`).
  Frozen props (all of them, beyond a 170–300-stud `SimDistance`) used to hang motionless while the sea
  moved under them — vertical span 0.00, a `Lifeboat` 3.60 above the water and a `Container` 5.93 below.
  They now follow the surface on a 0.35 s clock with a 6-per-frame budget and track it within
  **0.1–0.25 studs**. A3 holds: **0 of 10 tracked props vanished in 18 s** with a moving camera.
- `MaxCachedRecords` must stay ≤ 3000. Do not add a despawn path that ignores the sight check.

### Fishing (`docs/audit/06-fishing.md`)
- The full cast → bite → catch → retention cycle was observed from a client probe. Caught fish used to
  accumulate forever (D-24, fixed): retention now 31 → 24 with the new fish kept, `MaxRetained 24`,
  `MinAge 20`, `CullNearPlayerDistance 250`, `HardCeiling 40`. Rojo now actually places the rod and the
  FloatingGui (D-25). Bite timing: 7 samples, 7.3–10.0 s = `flyDur + 3.5–7`.
- No `AlignPosition`/`AlignOrientation`/`BodyVelocity`/`BodyPosition` anywhere in the fishing sources.

### Sound (`docs/audit/05-sound.md`)
- All 12 IDs load at their documented lengths. Calm `s = 0.30` → CalmBed 0.44 / Beach 0.12 / Rough 0 /
  Wind 0.08; rough `s = 1.00` → Rough 0.60 / Wind 0.35 / Beach 0.14 / CalmBed 0; night → Crickets 0.35 /
  NightWind 0.30 / Birds 0, day → Birds 0.25. **Nobody has judged the mix by ear.**

## 4. What is still open — this is your work list

Work in this order. Items 1–6 are code you can do alone; 7–10 need a live human and should be prepared,
not guessed at.

### 1–2. The two water decisions that are already diagnosed (highest visual payoff)
- **D-29 — the wave field stops at ~800 studs and the rest is a flat plate.** A chunk is only computed
  inside `MaxChunkRenderDistance = 800`, but culling a chunk does not hide it: the plane is one MeshPart,
  so culled vertices are still drawn at their last written position. Measured: 620/656 vertices moving at
  200 studs, **154/319 at 500, 2/728 at 900**; rendered-vs-analytic error 0.12 studs inside 100 studs
  rising to 1.38 at 900–1000; the true wave at +900 studs was −1.77 while the mesh was flat. The cost of
  fixing it is ~21 % more chunks plus the ~46 % of vertices currently skipped. Present the three options
  (raise the distance to ~1400 and pay; shrink the plane so the flat ring is smaller; leave it) with
  numbers, then do whichever the user picks — or, if you are working unattended, implement it behind a
  setting and measure the cost with the perf loop in §5 before turning it on.
- **D-30 — the whirlpool is a 170-stud hole nothing physical knows about.** `Workspace.Whirlpool`
  (radius 150 at `313.61, 35.5, 292.16`, 314 studs from spawn) produces `DownwardForce / (Distance /
  Scale + 1)` = **−250 studs at the centre** with the authored `DownwardForce 250` and a hardcoded
  `Scale 15`. Measured in the client mesh: world Y down to **−169.1 / −171.1**, 10–18 vertices below
  −20. `GetVortexTransform` is called from exactly one place (the mesh worker) and both ship scripts skip
  whirlpool zones, so hulls, swimmers and props cross the visible funnel at wave height. The two
  levers are content (`DownwardForce`, `Scale`); the third option is to teach `WaveFloat` and the swim/
  ship code the same vortex so the pit is real. Ask before changing a designed feature.

### 3. Prompt 09's polish sweep, which is the only prompt item never finished
- Dead code: `node tools/call-graph.js` reports 41 modules / 94 exports / **31 orphans**. **Zero were
  removed, deliberately.** The tool cannot see self-references (it flags `ShipDrive.SailEfficiency`,
  which `Acceleration` calls two lines away) and the audit's own admin entry points (`GetStats`,
  `PlaceOne`, `ClearGenerated`, `CountNearby`, `GetCatalog`) are in the list — they have 19 references
  across `tools/` and `docs/`. The genuine candidates are four `Helper` functions (`IsInView`,
  `PointInEllipse`, `ScaledDistance`, `HashVector`) with 0 references in `src/`, in a vendored module the
  ROADMAP says not to rewrite. If you remove anything, remove only things you can prove are unreachable,
  in their own commit, with the call-graph evidence in the message.
- Docs drift: check every `.md` in the repo root against the code as it is now. `BOAT_HANDLER.md` was
  rewritten, `ROADMAP.md` has a dated verified-state section, `SWIMMING.md` was checked clean.
- Debug hygiene: `Settings.DEBUG` is `IsStudio()`-gated and used at 3 sites; `PERF.REPORT_EVERY` is 0;
  there are no `Dbg*` attributes (0 of 32) and no commented-out code blocks. Keep it that way.
- Console at the end of a Play session must hold no game errors. One known-benign line: the
  unapproved `rbxassetid://167123203` is requested once at join (D-04; both instances were muted).

### 4. Tooling debt
- **D-15**: `tools/find-dead-config.js` cannot parse `Gerstner/Settings` and reports "0 config keys, no
  dead keys" — a false pass on the one file whose dead keys matter (that module builds its table from a
  local). It was taught to read a config built in a local for a different case (`f5739f2`); finish the job
  or document the limitation where the tool prints its result.
- **The write counter in `ParallelWorker` counts vertices, not API calls** (`for _ in Computations do
  WriteCount += 1`). Any perf claim made with it is unsound. Fix the instrument before trusting a budget
  change: count `SetPosition` / `SetColor` / `SetColorAlpha` / `SetUV` calls separately.

### 5. The unverifiable-without-a-human list — prepare these, do not fake them
- The **occupied** `Client` ship path: every ship number in `07` is the server's unmanned path.
  `Humanoid:Move` yields `VehicleSeat.Throttle = 0`, so no probe can drive a hull through its real input.
- **Ship-on-ship** climb: a forced overlap was measured (contact detected on 8 parts, hull pushed down
  19.5 studs rather than riding up) but a driven collision needs two hulls and a driver.
- **The sound mix by ear.** Volumes are reads, not listening.
- **D-23**: no *rendered* prop is ever in the near band (`NearDistance 150` vs `MinPlayerDistance 200`).
  Fixing it changes what the sea looks like close to the boat — a taste call; the user owns it.
- **D-11**: the third-party trees exist only in the Studio place; they need the user's model files.
- **A still-water rig.** Wave state varies between 9 s windows more than most effects being compared
  (offset rms 1.09–2.07 on identical builds). Anything needing a small difference measured needs a fixed
  sea; consider building one (freeze `SeaStateAt` to a constant through a debug setting) before the next
  tuning pass, and document how to switch it on.
- **`SimDistance`**: raising `Config.Classes[*].SimDistance` does nothing live, because records capture
  `simDistance` at spawn (`FloatingObjectGenerator` ~line 1567). Regenerate to test it.

## 5. How to measure — the recipes that work, and the traps that cost this audit two rounds

**Live mesh (what the player actually sees).** During Play, from a client probe:
```lua
local em = game:GetService("AssetService"):CreateEditableMeshAsync(plane.MeshContent)
em:GetVertices() / em:GetPosition(id) / em:GetColors() / em:GetUVs()
```
`Content{SourceType=Object}` gives a live-reading copy — re-create it to see new state. Each call costs
**4.15 ms**, so use it for step size and continuity, never for frame-rate claims. ~1192 vertices sit
outside the frustum and get no computation; classify "far" by frustum containment
(`flat:Dot(lookXZ) > 0.35`), not by distance.

**Frame-time A/B (Studio only).** `Settings.PERF.REPORT_EVERY` must stay **0 in the repo**. For
measurement, copy Settings to a variant, set 300, push with `push_src.py`, `bash
tools/studio-probes/ocean/restart_play.sh`, pin the camera
(`workspace.CurrentCamera.CameraType = Scriptable`, then `CFrame`), wait ≥25 s, read
`tools/studio-probes/ocean/perf2.sh`, and **restore the repo Settings and read it back**. Two sessions
per variant; a change counts only if both agree on direction. In this environment frame-time noise is
large (four identical-settings sessions spanned 149–215 writes/worker), so state the noise, not just the
mean.

**Ships.** `bash tools/measure/ship-tuning.sh` runs the real `ShipDrive.luau` under plain Luau for top
speed, 0–90 % time, coast and turn radius. For the bounce, measure the hull **where it floats** (never
drop it 5 studs and call the splash a bounce), on the path the user is on: an **occupied** hull shows
`UnmannedBuoyancyForce` reading exactly **0**. Server probes cannot drive `VehicleSeat.Throttle`.

**Height math.** `bash tools/measure-height-error.sh` (physics vs mesh height error and cost) and
`bash tools/measure/jacobian.sh` (folds). Both run the **real** modules headless — read §6 of
`10-continue.md` for how they are assembled and the three traps (the wave table must be installed before
`WaveFloat` loads; each module ends with `return X` so wrap it; Luau 0.736 rejects `local a={}, b={}`).

**Colour/ramp.** `bash tools/measure/colour-ramp.sh` (new) runs the real `Helper.luau` with a
`Color3`/`Camera`/`Settings` stub.

### Traps that will waste your session if you forget them
- Do **not** count reversals from `AssemblyLinearVelocity` on a server-owned hull from a client probe —
  the property does not track replicated motion. Use position deltas, low-pass them, and require a swing
  threshold: raw frame deltas flipped sign 7 times in 4 s on a calm hull from replication quantisation
  (~0.03 studs). Clamp `dt` before deriving speed (two Heartbeats microseconds apart gave 299 studs/s).
- Do **not** sample the ocean surface at a hull's centre — ships use the mean of the four corner heights.
- Do **not** derive a frozen prop's pose from `AssemblyCenterOfMass` on an anchored model (it does not
  refresh; the Container swung 17→21 studs). Use the stored reference pose.
- `WaveFloat.HeightAt` with `HeightSource == "MESH"` and a nil zone throws; fall back to `"ANALYTIC"`.
  `WaveFloat.HeightAt` needs `t`. `ZoneManager:GetZoneParameters` and `GetNetworkOwner` throw in probes.
- Never write `main.CFrame` on a welded hull — use `model:PivotTo`. Union parts report bogus bounds.
- `survey_place` withholds `source` for large scripts, so source diffs show everything as different —
  use `parity_hash.py` (compares the plugin's own FNV-1a hash) and remember it reads a *saved* survey, so
  a stale file reports false diffs.
- `push_src.py` to a non-existent path silently creates a stray instance and reports success after a 502
  retry. Verify the path and read the hash back. Reading `.Source` in a probe throws
  `lacking capability PluginOrOpenCloud`.
- `python3` `str.replace` patches: assert the text occurs exactly once, and include the enclosing
  `local function` header when a call shape repeats.
- The bridge's **client** channel wedges intermittently; server probes keep working. `/tmp/runprobe.py`
  can vanish between sessions — recreate it if it is gone.

## 6. Definition of done, and how to report

For each item you change: **one commit**, message stating what was wrong, the measurement that proves
it (numbers, before → after), and what remains unmeasured. Then a document under `docs/audit/` (or an
append to the existing one) with the same content, more detail, and a "what could not be verified"
section. Update `docs/agent-prompts/10-continue.md` §3c/§3d and `docs/audit/01-defects.md`'s triage table
so the next agent inherits a current state.

Before you finish a session:
1. `node tools/check-syntax.js`, `node tools/smoke-test.js`, `node tools/validate-project.js` all green,
   `parity_hash` 41/41 after pushing every Studio-side change and reading the hashes back.
2. Secrets grep clean; `git status` clean; `.mcp/`, `probes/` and anything holding a token untracked.
3. Stop Playtest (`StudioTestService:EndTest("done")`) so the user can Ctrl+S.
4. Tell the user, in plain words: what changed, what they should look at in Play (with *where to look*
   and *what it should look like*), which decisions are theirs to make, and that the commits are on the
   PR branch (say whether they are pushed or still local, with a count).

Write the report as if the next reader has this document and nothing else.
