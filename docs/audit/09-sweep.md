# 09 — Polish and debug sweep

Final pass. Everything here is dated 2026-10-26/27. The defect table with a status for every entry
lives at the end of `01-defects.md`; this document is the sweep itself — what was checked, what was
found, and what was deliberately left alone.

---

## 1. A1 — triage: every defect has a status

23 entries, in `01-defects.md`:

| Status | Count | Entries |
|---|---|---|
| **Fixed** (with the commit) | 15 | D-01 `a4ef9a0` · D-02 `1cb64e2` · D-03 `1cb64e2` · D-04 2026-10-27 · D-06 `cb1adbd` · D-07 `5230580` · D-08 `856fb63` · D-09 `cb1adbd` · D-13 (as a symptom of D-18) · D-17 `a1b2685` · D-18 `a1b2685` · D-19 `a1b2685` · D-20 `5230580` · D-21 `5230580` · D-23-adjacent |
| **Hardened / closed** | 3 | D-12 closed as not-a-defect (the Boathouse is parked, `04`) · D-13 as a symptom · D-22 hardened by an invariant guard |
| **Won't fix** (with the reason) | 4 | D-05 (not in any property or script of any type) · D-10 (both zone scripts exist but one node answer per position) · D-14 (remotes are self-healing and live) · D-16 (documented setup step, the 3 "failures" are false) |
| **Open** (owner) | 3 | D-11 third-party trees = content work, needs the user's models · D-15 `find-dead-config` tooling debt · D-23 near-band question = the user's taste call |

## 2. A2 — no debug code: **PASS**

| Check | Result |
|---|---|
| `script_grep "args_gen_dbg"` over 79 scripts | 0 |
| `Dbg*`/`debug*` instance attributes, swept over `ReplicatedStorage`, `ServerStorage`, `Workspace`, `StarterPlayer`, `ServerScriptService` | **0 of 32** attributes |
| `REPORT_EVERY` anywhere in `src/` | only `Settings.PERF.REPORT_EVERY = 0`, the off value |
| Debug prints | none. `Settings.DEBUG = RunService:IsStudio()`, used at exactly 3 sites (`OceanParallel/init` ×2, `HeightLookup` ×1) |
| Commented-out code blocks | none found |

Two `print`s are **kept** deliberately: `[IslandGenerator] dynamic island streaming started. Render cap: 200`
and the equivalent from `FloatingObjectGenerator`. These are one-line "the system came up" notices, and
during this audit they were the thing that made D-20 (floating objects never starting) visible — the
PrintLine was *absent* while islands printed. Removing them would remove the cheapest evidence that
streaming is alive.

`SoftResponsiveness` is **not** a debug flag: it is a real config knob (`FloatingObjectConfig:337`, read
at `FloatingObjectGenerator:821` and `:1257`) and its value is 8, so the 24 that the prompt set tried was
already reverted.

## 3. Task 5 — dead code: **31 orphans found, 0 removed**

`node tools/call-graph.js`: 41 modules, 94 exports, 63 used, **31 orphaned**. `find-dead-config.js`:
0 dead keys in both modules it can parse.

**Nothing was removed, and that is the finding.** The tool over-reports, in two ways that matter here:

1. **It cannot see self-references.** `ShipDrive.SailEfficiency` is listed as an orphan, but
   `ShipDrive.Acceleration` calls it at line 190 of the same file. Removing it would break the sail model.
2. **The audit's own instrumentation lives in the "orphan" list.** `GetStats`, `PlaceOne`,
   `ClearGenerated`, `CountNearby`, `GetCatalog` are the admin/debug entry points this whole audit ran on —
   `/home/user` has **19 references** to them across `tools/` and `docs/audit/`. They are public API, not
   dead code.

The ROADMAP's guardrail also says explicitly: *"Don't delete the orphaned ocean API — it's the intended
interface."* The remaining genuine candidates are four `Helper` functions (`IsInView`, `PointInEllipse`,
`ScaledDistance`, `HashVector`) with **0 references anywhere in `src/`**, in a vendored module that the
same guardrail says not to rewrite. Logged as debt, not deleted: the benefit is zero (they are never
called, so they cost nothing at runtime) and the risk is merge friction with upstream.

## 4. Task 7 — documentation drift: **BOAT_HANDLER.md rewritten, others checked**

`BOAT_HANDLER.md` had drifted furthest (commit `fadbe84`). Five things in it were wrong, one of them
contradicting a standing user correction:

| Was | Is |
|---|---|
| "Sail (hulls with a `Sail` child only, currently `Boat`)" | `Boat` does not exist, and **no playable hull has a `Sail`**; the branch is dead code for the fleet |
| "Tuning lives in `ShipDrive.Defaults`" | `Defaults` is the fallback; each hull overrides by attribute (full table added) |
| "Draft: 0 on `Boat`, 5.5 on `WoodenShip`" | 5.5 / −7.3 / 3.5, and they were never physical drafts — they compensated for a frame error |
| "Open: … an explicit upward `VectorForce` spring with damping. **Not built yet.**" | That is what ships now use; both root causes and the before/after numbers are in the file |
| "`WoodenShip.Client` is still Disabled and was not updated" | Brought onto the current script in `a4ef9a0`; all three hulls carry byte-identical copies |

`ROADMAP.md`: its phase tables were already accurate and each row carries evidence, so nothing there was
rewritten. Added a dated **verified-state** section (`c86d9e8`) summarising what this pass measured, with
pointers to `01`–`09`. `SWIMMING.md`: read against `SwimModel.luau` and `SwimClient.client.luau`, no
drift found, no change.

`docs/agent-prompts/10-continue.md` keeps the running "corrections to the prompt set" list — now nine
entries, including the `#x:Method()` parsing gotcha that cost time during this pass (it parses as
`(#x):Method()`, which is a syntax error).

## 5. Task 3 — polish, and what the console says now

The debug sweep is best measured by what Play actually reports. Last session, grouped by message:

```
2x  Failed to load sound rbxassetid://167123203: Asset is not approved for the requester
1x  Plugin "Maor's Gui Animation Plugin" was denied script injection permission
```

Both are known and not ours to fix: the first is the engine preloading the two dead `Splash` instances
(§D-04; the loops themselves are stopped), the second is a third-party Studio plugin. **No game errors.**
For comparison, the first Play of the previous session produced
`ServerScriptService.FloatingObjectGenerationServer:45: attempt to index nil with 'Streaming'` and the
floating-object system never started.

Polish items examined and deliberately **not** changed:

* The three `TODO` comments in `src/` are all in vendored or upstream code (`ParallelWorker`,
  `OceanParallel/init`, `Helper/UV_SCROLL_SPEED`) and point at Roblox-side issues. The ROADMAP guardrail
  says don't rewrite those modules.
* `Workspace.FloatingGui` looks like a leftover at first glance but is the fishing rod's floating UI
  (`FishingClient:17` requires it, `FishingConfig.Gui` is passed to it). In use.
* The two muted `Splash` sounds (D-04) still exist as instances with `SoundId` set. Nothing references
  them and they no longer play; clearing the IDs would also stop the preload warning, but deleting a
  user's content is not a polish decision. Left as the user's call.

## 6. Prompt 08's remaining measurement — islands

Same frame, same player, `CollectionService:GetTagged`:

| Tag | Rendered | 0–300 | 300–600 | 600–1200 | 1200–2600 | nearest-neighbour |
|---|---|---|---|---|---|---|
| `FloatingObject` | 11 | 1 | 4 | 6 | 0 | mean 165, median 178, min 27, max 264 |
| `Island` | 1 | 1 | 0 | 0 | 0 | n/a (one sample) |

`IslandGenerator.GetStats()`: `Streaming=true`, `CachedRecords=34`, `RenderedIslands=1`,
`MaxRenderedIslands=200`.

**34 cached but 1 rendered is by design, not a defect.** Records are generated for every cell within
`Streaming.GenerationRadius` 2600; a model only rises when a player is within
`record.radius + Rise.TriggerDistance (220)` (`isAnyPlayerCloseEnoughToRise`). At the spawn point exactly
one island satisfies that. The floating-object ring pattern is the one to tune: it shows the
`MinPlayerDistance` 200 dead zone working (0 props nearer than 200) and `CacheDistance` 900 as the outer
edge (0 beyond 900).

`RenderedIslands=1` also means the prompt's "sparser, less compacted, less periodic" requirement **cannot
be assessed on islands from one sample** — it needs a player to travel. Recorded, not claimed.

## 7. A3 — repo checks at the end of the pass

```
node tools/smoke-test.js   → 83 passed, 0 failed (4 warn lines)
node tools/check-syntax.js → 23/23 Luau files parsed
node tools/validate-project.js → 0 errors, 0 warnings, project tree consistent
luau-compile (binary)      → clean on every changed file
parity_hash.py             → 39/39 repo↔Studio pairs match, 0 differ, 0 missing (79 scripts)
```

## 8. What is still open, and who owns it

| Item | Owner | Why it is not done |
|---|---|---|
| D-11 third-party trees exist only in Studio | user | Needs the user's models; cannot be reconstructed from a repo |
| D-15 `find-dead-config` sees 0 keys in `Gerstner/Settings` | tooling | Does not understand that module's shape; no runtime effect |
| D-23 no rendered prop is ever in the near band | user | `NearDistance` 150 vs `MinPlayerDistance` 200. Fixing changes what the sea looks like close to the boat — a taste call |
| Occupied (`Client`) ship path | anyone | Every ship number in `07` is the server's unmanned path; boarding a hull is the check |
| Ship-on-ship climb | anyone | **Partially observed** (2026-10-27): with two hulls forced into the same space the contact is detected (8 parts) and the hull is pushed *down* 19.5 studs rather than riding up, but that was a forced overlap, not a driven collision. Still wants two hulls driven together |
| The sound mix by ear | user | Volumes are reads, not listening |
| ~~Fishing cast cycle~~ | **done 2026-10-27** | Driven from a client probe with `tool:Activate()`; found and fixed D-24 (caught fish were never removed) and D-25 (Rojo never placed the rod). Detail in `06-fishing.md` |
| Buoyant prop response sweep | anyone | `PlaceOne` near the player is blocked by `MinPlayerDistance`; the switch to the soft cadence (`08` §7) is the likely cause of the visual difference |

## 9. What to try in Play

1. **The sea should have floating props** — 11–23 in the 200–900 stud ring, none closer than 200.
2. **Ships should not bounce.** Board each hull; the vertical velocity no longer reverses at all.
3. **The Boathouse should steer** (its 2 011 493-torque yaw lock is gone) and should settle instead of
   rocking (its 400 000-stud down-force is gone).
4. **`Draft` is a clean 1:1 lever** — one stud of attribute is one stud deeper. Values today are 5.5 /
   −7.3 / 3.5 and are guesses left over from the frame bug; set them by eye.
5. **Turn away from a prop and back** — it may be culled while unseen, and must not vanish while you are
   looking at it.
6. **Listen to the sea** — calm/rough/day/night are wired and measured, but nobody has judged the mix.
