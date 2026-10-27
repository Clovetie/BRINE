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
5. **Secrets.** Before every commit, grep the tree for the two secret prefixes and make sure it
   returns nothing: the GitHub token prefix (`github_pat`) and the first 8+ characters of the Studio
   bridge token. Do not paste either full value into any file -- including this one. (The first
   version of this file quoted the bridge token verbatim inside the grep example, which is exactly
   the mistake the rule exists to prevent. It was caught by running the grep, and that commit is
   still in the branch history -- rotate the bridge token.)

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
| `142c509` | This continuation prompt |
| `cb1adbd` | Fold analysis (no folds anywhere) + Studio cleanup (79 scripts) |
| `a4ef9a0` | `Ship/Client` onto the live `WoodenShip`, parity 45/45 |
| `bcfba3c` | Audit 05 + 06: sound and fishing measured; D-05 closed by inspection |
| `a1b2685` | **Ships: per-hull handling, servo goal frame (D-18), Boathouse movers (D-17)** |
| `8410a97` | Tooling: hash parity (32→39 pairs), per-hull attribute manifest; continue at 08 |
| `5230580` | **Floating: the system never ran (D-20), pivot-vs-centre seating (D-21), FloatRatio 0.7** |

**Nothing after `a4ef9a0` is pushed** (still no GitHub token or `origin` in the new sandbox): this session had no GitHub token and no `origin`
(`git remote -v` is empty), so `bcfba3c` and `a1b2685` are local commits on the branch.
Push them with the token URL before opening or updating PR #9.

Read next, in this order: `docs/audit/01-defects.md` (the work list),
`docs/audit/02-waves-findings.md` (what S1/S2/S3 mean and the numbers),
`docs/audit/03-perf.md` (the write-budget A/B and the solver cost).

**Repo checks all pass at HEAD**: smoke 83/0, syntax 23, validate 7 models 0 errors,
`luau-compile` 41/41, tree clean.

---

## 2. Tooling that now exists — use it, do not rebuild it

### `tools/studio-probes/bridge/parity_hash.py <survey.json>` (new, committed)

The only parity check to trust. It compares the plugin's own `hash` per declared pair and
reports trailing-newline-only pairs as matches. Dump the survey first:

```bash
MCP_MAX=8000000 python3 .mcp/call.py survey_place '{"includeSource":true}' > /tmp/s.json
python3 tools/studio-probes/bridge/parity_hash.py /tmp/s.json
```

### `tools/studio-probes/ships/apply_ship_attributes.py` (new, committed)

The per-hull ship tuning is **attributes on the models**, which Rojo cannot carry, so the
script is the source of truth. `--check` reads the place back and prints what it holds.

### `bash tools/measure/ship-tuning.sh` (new, committed)

Prints each hull's top speed, 0-90 % time, coast curve and turn radius by running the real
`ShipDrive.luau` under plain Luau. Use it before claiming a handling number.


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
6. **`07-ships-and-physics.md` names ships that do not exist.** `Boat`, `Boat1` and `Template` are not
   in the place; the fleet is `ServerBoat` (reference, legacy handler), `WoodenShip`, `MisoSoup`,
   `Boathouse`. Every draft/sink row in that prompt mentioning the missing three is void.
7. **There is no `Workspace.singletons` in the place.** The Rojo project maps it, but each ship model
   carries its own `Handler` and `Client` copy. A change to "the singleton" must be pushed three times,
   and each hull can silently drift (that was D-01). `parity_hash.py` checks all three.
8. **`survey_place` withholds `source` for large scripts** (`sourceWithheld: true`), so a
   source-comparison parity report shows every big script as a difference and prints "studio 0 lines".
   Use `tools/studio-probes/bridge/parity_hash.py <survey.json>` instead: it compares the plugin's own
   `hash` (FNV-1a 32) and reports trailing-newline-only pairs as matches. Current state: **32/32 match,
   0 differ, 0 missing**.
9. **`BodyPosition` has no `Enabled` property.** If it is parented it is on, which is why the
   Boathouse's legacy movers were live rather than inert. Do not read "no `Enabled`" as "disabled".

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

**Prompt 05 (sound)** — all 10 `AmbientSea` tracks and both unused user IDs load at their
documented lengths; calm `s=0.30` → CalmBed 0.44 / Beach 0.12 / Rough 0 / Wind 0.08, rough
`s=1.00` → Rough 0.60 / Wind 0.35 / Beach 0.14 / CalmBed 0; fixed-camera depth gives
camY 60 → depth −35.07 / UW 0, camY 24 → −0.04 / UW 0, camY 19 → +3.34 / UW 0.67; night →
Crickets 0.35 / NightWind 0.30 / Birds 0, day → Birds 0.25. The mix has never been judged by
ear — that is the user's call. See `docs/audit/05-sound.md`.

**Prompt 06 (fishing)** — no `AlignPosition`/`AlignOrientation`/`BodyVelocity`/`BodyPosition`
anywhere in the fishing sources; the grab is a `DragDetector` built per caught fish
(`makeDragDetector`, line 375, called at 514), so a rod with nothing caught reports 0
legitimately. `FishEvent` + `Action` live on `tool.FishingRemotes`. A full cast→catch→drag
cycle was **not** observed. See `docs/audit/06-fishing.md`.

**Prompt 07 (ships)** — see `docs/audit/07-ships.md`. Settled `Main.Center` offsets after the
fix: `WoodenShip` +0.88, `MisoSoup` +0.48, `Boathouse` +0.73; before the fix `WoodenShip`
sat at −4.00 with its deck 2.3 studs under water. Per-hull handling live: tops 26.0 / 18.0 /
13.9 studs/s, turn radii 113 / 163 / 58 against the reference's 29.1 / 58.2. The reference
`ServerBoat` rides **12.4 studs above** the water — that is the hover, and it is out of bounds.

| Item | Result |
|---|---|
| S2 rest-vs-displaced | p99 **1.2986 → 0.0094** studs at rough sea; live engine check 0.0010 studs. Fixed in `WaveFloat.HeightAt`. |
| S1 write cadence | far-vertex step **0.151 studs/write (p99 0.253)** at 20 Hz vs **0.050 (p99 0.085)** at 60 Hz. `FAR_WRITE_EVERY` now 1, cost +0.46 ms/frame. |
| S3 sea-state in lerp | Dismissed with a bound: ΔSeaState ≤ 0.0015 per lerp window; chord sag ≈ 0.001 studs. |
| S5 zone multipliers | Checked by reading both paths; no mismatch. |
| Write cost model | Serial ms is linear in writes at **0.82 µs/write**; parallel moved only +10%, so the budget never saved compute. |
| UV write cost | ~**5.7 µs** per UV write vs 0.82 µs per position write. **One session each — a lead, not a result.** |

### Open

- **"Waves intersecting each other" is ruled out as a fold.** `bash tools/measure/jacobian.sh` runs
  finite differences on the real `ComputeTransform`: 0 folds in calm, rough, the live field, ×1.5 and
  ×2.0 amplitude, and inside the `RoughSeaArea` zone despite its `AmplitudeMultiplier = 2.5`
  (Σ steepness 1.725 > the classic ≤ 1 rule) — so that zone is **measured safe**, do not "fix" it.
  Only a uniform ×2.5 produced a single fold (1 in 41 405 samples). If a user still sees intersecting
  waves it is a rendering/LOD seam, not the height function.
- **"Water through hulls" is hull depth, not crest height**: freeboard is 34–60 studs against a
  4.73-stud crest envelope, so no crest reaches any deck. It was the deck sitting *under* the water —
  now D-18, fixed, but the absolute waterline per hull is still a taste value.
- **Ship-on-ship climb** was not re-run this session (needs two hulls driven together with a client
  aboard). Last numbers stand: side control `Boat` 3.22, `WoodenShip` 3.35.
- **The 6 Hz vertical vibration** on a settling hull could not be separated from server load
  (`dt` ranged 12.5–54 ms while probing). If it shows at a steady 60 fps, try
  `Responsiveness = 6` in `Handler`/`Client`.
- **The occupied (`Client`) path** was never sampled: every ship number here is the server's unmanned
  path. Boarding a hull is the check.
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

**0. Push.** `git remote add origin https://<token>@github.com/Clovetie/BRINE.git` and push
   `arena/ocean-sound-and-audit`. `bcfba3c` and `a1b2685` are local only.

**1. Prompt 08 — DONE except two sub-items.** See `docs/audit/08-floating.md`. The big find was
   D-20: the server script threw on a nil `Config` before it ever called `Generate()`, so the sea had
   **no props at all**; D-21 was the float height being computed for the box centre but applied to the
   pivot. Both fixed, `FloatRatio` 0.6 → 0.7 for Small and Medium, A3 passes for real. Left open: the
   buoyant path was measured once end to end, islands were not re-measured, and D-23 (no rendered prop
   is ever in the near band) is recorded for the user rather than changed.

**2. Prompt 09 — polish and debug sweep.** The audit list is the input; `01-defects.md` carries the
   current state of every item, including the ones that were closed with numbers this week.

**3. The open verification list, in `01-defects.md` order** — ship-on-ship climb, the occupied
   (`Client`) path on each hull, the 6 Hz vibration at a steady 60 fps, and the two sound fades that
   need a random timer (`Gust` on rough only, `Birds` by day) rather than a volume read.

**4. Only then ask the user.** They said "don't ask anything from me yet". The questions waiting for
   them, in importance order: (a) does the fleet waterline look right now that `Draft` is a clean 1:1
   lever, and should the hulls ride higher (toward the reference's +12.4) instead; (b) is the per-hull
   handling spread (26 / 18 / 14 studs/s) the direction they want, given the `ServerBoat` they drive
   does 29; (c) the unused 133 s calming sound — wire it in or leave it.

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
