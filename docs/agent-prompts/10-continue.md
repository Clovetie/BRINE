# 10: Continue the BRINE audit, fix, and polish

Written by the agent that did prompts 01 and part of 02/03, for the agent that picks this up.
Read this file **first**, then `00-README.md`, then the numbered prompts for whatever you touch.
Everything in `00-README.md` still applies; this file only adds state, corrections, and the order I
would work in.

---

## 0. Rebuilding the environment (do this before anything else)

The last session started in a **fresh sandbox with nothing in it**: no clone, no bridge client, no
`.tools/`. Section 0 of `00-README.md` assumes all three exist. If `/home/user/BRINE` is missing:

1. **Clone** the PR branch (never `main`):
   ```
   git clone -b arena/ocean-sound-and-audit "https://x-access-token:<TOKEN>@github.com/Clovetie/BRINE.git" /home/user/BRINE
   cd /home/user/BRINE && git fetch --unshallow
   ```
   Then set an identity or commits fail: `git config user.name "Arena Agent"`,
   `git config user.email "agent@arena.ai"`.
2. **Toolchain.** `.tools/` is gitignored and will not be there. Run `bash tools/setup-tools.sh`
   (pins Luau 0.736, styLua 2.5.2, selene 0.31.0) and `npm ci` in `tools/`.
   **This matters:** without `.tools/bin/luau-compile`, `tools/check-syntax.js` falls back to
   `luaparse`, which cannot parse Luau `if-then` expressions or nested table types, and reports
   **3 false failures** (`SwimClient.client.luau`, `AmbientSea.client.luau`,
   `ParallelWorker.client.luau`). They are valid Luau. This is defect D-16; do not "fix" them.
3. **Bridge client.** `/home/user/.mcp/call.py` and `/home/user/probes/mcp_init.py` are not in the
   repo (they hold the token) and must be recreated. The interface the repo's probe scripts expect:

   ```
   python3 .mcp/call.py <tool> '<json-args>'      # e.g. probe '{"dm":"edit","timeout":30,"code":"..."}'
   python3 .mcp/call.py --init                    # fresh session, writes /tmp/mcp_sid
   ```
   It must POST JSON-RPC to the tunnel `/mcp` with `Authorization: Bearer <token>`, handle
   `Mcp-Session-Id` on initialize, accept `text/event-stream` responses, and **not truncate output**
   (`survey_place` returns ~950 KB). I used a `MCP_MAX` env cap of 5 MB for the big reads.
   My client lives at `/home/user/.mcp/call.py` in that sandbox and is a good starting point if it
   survived; if not, rewrite it from these notes. Never commit it.
4. **Helpers that exist in the repo** and are worth using instead of rewriting:
   `tools/studio-probes/bridge/push_src.py` (`<parent> <name> <className> <repo-relative-path>`),
   `tools/studio-probes/ocean/restart_play.sh`, `.../perf2.sh`,
   `tools/studio-probes/ocean/push_file.py`.
   `push_src.py` takes the repo path **relative to `/home/user/BRINE`**.
5. **Secrets.** Before every commit: `git grep -n "github_pat\|<BRIDGE-TOKEN-REMOVED>"` must return
   nothing.

---

## 1. Where the branch stands

Branch `arena/ocean-sound-and-audit`, PR #9 into `main`. `main` is at `525a9ec` (do not push to it).

| Commit | What |
|---|---|
| `1a1339d` | `docs/audit/01-inventory.md` + `01-defects.md` — 41/45 parity pairs match, 16 defects |
| `4e5ee90` | **Ocean: Gerstner horizontal inverse** in `WaveFloat.HeightAt` (S2, "colliding") |
| `ec336b8` | **Ocean: `FAR_WRITE_EVERY` 3 → 1** (S1, distant 20 Hz stepping) |
| `856fb63` | Fishing: adopt live rod-UI tuning (D-08) |
| `1cb64e2` | Islands: real rise/sink SFX ids (D-03) |
| `6e6d565` | Audit: record the user's ship requirements |

Read next, in this order: `docs/audit/01-defects.md` (the work list),
`docs/audit/02-waves-findings.md` (what S1/S2/S3 mean and the numbers),
`docs/audit/03-perf.md` (the write-budget A/B and the solver cost).

**Repo checks all pass at HEAD**: smoke 83/0, syntax 23, validate 7 models 0 errors,
`luau-compile` 41/41, tree clean.

---

## 2. Tooling that now exists — use it, do not rebuild it

### `tools/measure-height-error.sh` (new, committed)

Runs the **real** `Gerstner/init.luau` and the **real** `WaveFloat.luau` under
`.tools/bin/luau` with a `Vector3`/`Vector2` shim, and reports physics-vs-mesh height error plus a
cost benchmark.

```
bash tools/measure-height-error.sh
```

It concatenates, in order: `tools/measure/shim.luau`, the Gerstner module wrapped in a function,
`tools/measure/stubs.luau` (Settings/HeightLookup/game stubs **and the wave table**), the WaveFloat
module wrapped in a function, then `tools/measure/height-error.luau`.

Two traps I hit, so you do not:

- **The wave table must be installed in the stub *before* WaveFloat loads.** `WaveFloat` captures
  `local Waves = Settings.Waves` at load time; if you set it afterwards, `HeightAt` silently returns
  a flat `PLANE_Y` and every error number looks like the raw displacement.
- **Each module ends with `return X`**, so each must be wrapped in `(function() ... end)()` or the
  file stops parsing at the second `return`.
- Luau 0.736 will not parse `local a={}, b={}` (two empty tables in one `local`). Split the lines.
  Also avoid the identifier `vec`. Both errors read as "Expected identifier ... got '='".

Self-checks the harness prints: `Σ WaveAmplitude = 4.7317` and wave 1 `k = 0.108331`,
`c = 9.5112`, which match the analytic values.

### Reading the live ocean mesh from a client probe (recipe, not yet a script)

```
local em = game:GetService("AssetService"):CreateEditableMeshAsync(plane.MeshContent)
em:GetVertices()      -- 3301 for OceanPlane
em:GetPosition(id)    -- live, distorted
```

- `Content{SourceType=Object}` returns a **live-reading** copy: re-create it to see new state.
- Each call costs **4.15 ms**; one per rendered frame drops the client to **20 fps**, so use it for
  step size and continuity, **never** for frame-rate claims.
- ~1192 vertices sit outside the view frustum and get no computation on any frame. Classify "far"
  vertices by frustum containment (`flat:Dot(lookXZ) > 0.35`), not by distance, or your sample is
  dominated by static vertices and you will conclude "far vertices never update".

### Perf measurement loop (Studio only)

`Settings.PERF.REPORT_EVERY` must stay **0 in the repo**. For measurement, copy Settings to a
variant, set 300, push with `push_src.py`, `restart_play.sh`, wait 30 s, read `perf2.sh`, and
**restore the repo Settings afterwards and read it back**. Variants used last time:
`REPORT_EVERY=300` with `FAR/UV = 3/3`, `1/3`, `1/1`. Two sessions per variant; a change counts only
if both agree on direction.

---

## 3. Corrections to the prompt set (read before trusting a prompt)

1. **The five debug hooks named in `01` do not exist.** `args_gen_dbg_on`, `args_gen_dbg_fix`,
   `args_miso_noguard_on`, `SoftResponsiveness 24`, and the `Dbg*` attributes on
   `SoundService.AmbientSea` are absent from both the edit DataModel and all 81 scripts (9
   attributes exist, none is a switch). They may be runtime-only, so re-check **in Play** on spawned
   floating objects before closing that item.
2. **`Workspace.Ocean` is empty in edit mode.** The planes are built at runtime by `OceanParallel`
   (9 planes: `OceanPlane` + 8 `SecondaryPlane`). Any prompt that says "look at the mesh in Studio"
   means during Play.
3. **There is no `SEA_STATE_ROUGH` constant.** Calm is `Gerstner.SEA_STATE_CALM = 0.3`; rough is the
   literal `1`.
4. **`docs/work-notes/ocean/NOTES.md` serial ms does not match this host.** My write-count numbers
   reproduce the documented rows (127 vs "110–128"; 237.5 vs "237–239") but serial time is 35%
   higher (0.297 vs 0.22). The notes do not record `n`, session count, or host, so it is not a
   controlled comparison and **not** a regression. Do not cite it as one.
5. **`find-dead-config.js` reports "0 config keys, no dead keys" for `Gerstner/Settings`** — a false
   pass on the one file whose dead keys matter (D-15). It does not understand that module's shape.

---

## 4. Rules from the user (do not break)

Carried forward from `00-README.md`, plus what changed this session:

- **Do not change `ServerBoat`.** Its own script stays as-is. Note that it reads buoyancy through
  `BoatManager` → `WaveFloat`, so a fix in the shared solver moves its ride height by consequence.
  That already happened (`4e5ee90`, ~1.1 studs) and is intended; keep saying so out loud.
- **Keep the fishing grab on `DragDetector`.** Never `AlignPosition`/`AlignOrientation` for fishing.
  (Ships and swimming legitimately use movers; that rule is fishing-only.)
- **Do not delete `Workspace.Part`** — it is the platform slab (Part, 121×230×98, at
  `16.156, -44.758, 174.041`, anchored).
- **No overhang-sink code** for unsupported platforms; the user will make platforms solid.
- **Floating objects must never despawn, cull, or expire while in a player's sight.**
- **Hirabelan is a real player**, not a rig.
- **No ocean texture work.**
- **Never push to `main`.**
- **Studio is authoritative for taste/tuning values** where repo and Studio disagree (applied to
  D-08; the user said "Studio values are the main point").
- **No ship has a sail.** Verified: `WoodenShip` children are `Center, Truss, VehicleSeat, BoatWheel,
  Motor, Union, Union, Prim, Main, Handler, Client`; `MisoSoup` are `Handler, Union, Main,
  VehicleSeat, Parts, Client`. Only `ServerBoat` has a child literally named `Sail`, and it runs the
  legacy handler, not `ShipDrive`. **So the entire sail/wind drive path is dead for the playable
  fleet**: `Ship/Client.client.luau:205` does `if Ship:FindFirstChild("Sail") ... else 0`, so
  `sailAccel` is always 0, and `ShipDrive.SailEfficiency`, the apparent-wind term, `WindSpeed` and
  `SailAccel` never contribute. Propulsion is engine-only. Do **not** "fix" a sail; treat it as a
  dead path to record (P3) and keep the guard.
- **Each ship needs its own speed and steering settings** (new requirement, recorded in
  `01-defects.md`). The `Ship` singleton under `src/Workspace/singletons/Ship/` is deployed to all
  three hulls, so today all three share one tune. Split it per hull — but **fix D-01 first**,
  because `WoodenShip.Client` in Studio is still 243 lines against the repo's 269.

---

## 5. What is verified, and what is open

### Closed with numbers

| Item | Result |
|---|---|
| S2 rest-vs-displaced | p99 **1.2986 → 0.0094** studs at rough sea; live engine check 0.0010 studs. Fixed in `WaveFloat.HeightAt`. |
| S1 write cadence | far-vertex step **0.151 studs/write (p99 0.253)** at 20 Hz vs **0.050 (p99 0.085)** at 60 Hz. `FAR_WRITE_EVERY` now 1, cost +0.46 ms/frame. |
| S3 sea-state in lerp | Dismissed with a bound: ΔSeaState ≤ 0.0015 per lerp window; chord sag ≈ 0.001 studs. |
| S5 zone multipliers | Checked by reading both paths; no mismatch. |
| Write cost model | Serial ms is linear in writes at **0.82 µs/write**; parallel moved only +10%, so the budget never saved compute. |
| UV write cost | ~**5.7 µs** per UV write vs 0.82 µs per position write. **One session each — a lead, not a result.** |

### Open

- **Two of the user's four collision symptoms are unexplained**: *waves visually intersecting each
  other*, and *water punching through hulls*. S2/S1 explain the other two (hover/sink, distant
  stepping). See §6 action 1.
- **S4** detail boundary at `MeshDetailDistance = 120`: not measured.
- **S6** stale chunks past `MaxChunkRenderDistance = 800`: not measured (belongs with prompt 04).
- **A2** is met for the write cadence by construction, but there is no full calm→rough transition
  trace.
- **Nothing about how the water looks** is verified. `capture_viewport` is a software rasteriser
  that does not draw Roblox water. Everything visual is the user's eye.
- **Solver cost in the real engine**: the 4.0× `HeightAt` figure is headless Luau, not Roblox. If it
  is material, `WaveFloat.INVERSE_STEPS = 2` still passes A1 (p99 0.0343) at 2.98×.
- **Hull tracking** came back null (sd ratio 1.0×) — the test had no discriminating power, not proof
  of no effect. Do not cite it either way.

---

## 6. What I would do next, in order

**1. Explain the two remaining collision symptoms analytically (no user needed).** This is the
   highest-value open question and it is cheap:

- *Waves intersecting each other* is a **self-intersection / fold** question, and it is decidable
  without playing: compute the determinant of the displacement map's horizontal Jacobian,
  `J = I + Σ Q_i k_i A_i [dir dx², dx dz; dz dx, dz²] · (-sin φ_i)`, over a grid and a few times. A
  negative determinant means the surface folds over itself and the render will show waves crossing.
  The steepness parameters sum to 0.69, which is *below* the classic Σ Q ≤ 1 no-loop bound, so I
  expect no folds and the cause to be something else (chunk-boundary seams, or the far lerp) — but
  measure it rather than assuming. The `tools/measure` harness gives you the real module in-process.
- *Water through hulls* is a **freeboard vs crest** question: amplitude sum is 4.73 studs, so if a
  hull's deck sits less than ~4.73 studs above mean water, the crest will visually wash over it.
  Each ship carries a `Draft` attribute (`WoodenShip 5.5`, `Boathouse 3.5`, `MisoSoup -7.3` — the
  negative one is suspicious, D-13) and `WoodenShip`/`MisoSoup` carry `SinkRestOffset`. Compute
  freeboard per hull from the geometry and compare against the crest envelope.

**2. Prompt 09 debug/leftover sweep in Studio** (all read-and-verify, low risk, each its own commit):

- Delete `Workspace.SingleHeightLookup.LookupTesting` — a 15-line Script running
  `HeightLookup.Lookup(..., 'PRECISE', ...)` on **every `Stepped` frame** forever, plus a replicated
  position write. It also contaminates any Play measurement.
- Delete the duplicate `ReplicatedStorage.Gerstner.init` (341 lines, same hash `13697039` as its
  parent, required by nothing).
- Fix `ServerScriptService.FloatingObjectGenerationServer` in Studio: it hardcodes
  `minInterval = 0.1` instead of reading `Config.Streaming.CameraMinReportInterval`, and declares an
  unused `Config`. Direction: repo → Studio.
- Deal with the two `Splash` sounds on `rbxassetid://167123203`, which is **not approved**: 30 of the
  45 console warnings in one session, volume 0, looping, playing. Either delete the sound objects or
  find an approved id — ask the user which, do not invent an id.
- Attribute `rbxassetid://203785492` ("Asset type does not match requested type", 15 of 45
  warnings). It is **not** in any instance property or any script; re-check from a live client where
  the requester is named.
- Decide and record what to do about the third-party trees that exist only in Studio
  (`UsefulFunctions` 835 lines + 12 UI scripts, `VoxBreaker` 1407 + `PartCache`): vendor them under
  `src/` or document that the place must not be rebuilt from the repo. D-11.

**3. Prompt 04 seam/immersion measurements.** The seam is hidden by client fog 500→880; that is
   runtime-only, so read `Lighting.FogStart/FogEnd` from a **client** probe in Play and confirm the
   numbers and that the mesh outer edge (planes at ±1872, mesh local ±936) is actually inside the
   fog. Then chase S6.

**4. Prompt 05 sound.** Ten sounds in `AmbientSea`; verify all 12 user ids load **by reading
   `Sound.IsLoaded`/`TimeLength`**, not by volume alone. The mix has been verified by volume reads
   and never by ear — say so. The calming track `131586509457092` and the cave track `273398061` are
   unused: ask before deleting or wiring them in.

**5. Prompt 06 fishing regression, 08 floating/islands.** Not started.

**6. Prompt 07 ships** — but only the parts that need no design input: D-01 (`WoodenShip.Client` is
   stale, repo → Studio, read back), then the per-hull tuning split the user asked for.

---

## 7. Do not

- Do not fix things during an audit-style pass without recording them; the split between "measured"
  and "believed" is the whole value of the docs in `docs/audit/`.
- Do not claim a frame-rate result. The notes warn frame-rate A/B on this host is unreliable (23–63
  fps across runs) and there is no same-window control.
- Do not trust a Studio push until you have read it back and diffed it against the repo. Every push
  in the last session was verified that way; keep it up.
- Do not leave Play running when you stop. `probe` with `dm: server` and
  `StudioTestService:EndTest("done")`; `start_stop_play` with `stop` from edit does not work.
- Do not delete `Workspace.Part`, `ServerBoat`, or the sound folder.
- Do not write a token into any file, commit, or doc.

---

## 8. Report format

For every prompt: what changed (files + commits), what was verified (with the numbers and the exact
command or probe), what was not verified (with the reason), and what needs the user's eyes or ears.
One commit per fix, measurement in the body. If a prompt contradicts the live place, say so in the
doc rather than silently following the prompt — five such contradictions are already listed in §3.
