# 09: Polish and debug sweep

## When
Last. Run after prompts 01 to 08 are done, or in parallel with them only for files they are not touching.

## Goal
Clean up everything that is still wrong after the fixes: defects from `docs/audit/01-defects.md` that were not fixed, leftover debug code, tooling problems, documentation drift, and polish items that the user would notice.

## Inputs
- `docs/audit/01-defects.md` (the defect list). Work through every P0 and P1 first, then P2. P3 is debt; log it and do not fix it unless it is trivial.
- The per-area audit docs from `02` to `08`.

## Tasks
1. **Triage.** Sort the defect list by severity and by owner (which prompt). Close the items that the other prompts already fixed, with the commit that fixed them.
2. **Debug.** For each remaining P0 or P1 defect, reproduce it, find the root cause, fix it with the smallest safe change, and verify it. Record the reproduction steps.
3. **Polish.** For each P2 item, fix only what the user would see or hear. Typical polish items: a wrong label, a stuck UI state, a sound that starts twice, a visual pop, a timeout that does not reset.
4. **Leftover debug code.** Search the repo for debug prints, debug attributes (`Dbg*`), commented-out blocks, and `REPORT_EVERY` values other than 0. Remove them, or move them behind a Studio-only flag (`game:GetService("RunService"):IsStudio()`), as `Settings.DEBUG` already does.
5. **Dead code.** Use `tools/find-dead-config.js` and `tools/call-graph.js`. Remove only what is provably unused, and say so in the commit.
6. **Tooling.**
   - `tools/audit.sh` has a mode change only. Decide whether to restore it or commit it; do not leave it as an unexplained change.
   - `.tools/bin/*` loses its exec bit. Document the `chmod +x` step (it is in `00-README.md`).
   - `tools/node_modules` goes missing. Document the `npm ci` step (it is in `00-README.md`).
   - `selene` cannot lint Luau here. Note it in the README (it is).
7. **Documentation drift.** Update `ROADMAP.md`, `BOAT_HANDLER.md`, `SWIMMING.md`, and the work notes so they match the code and the measured state. Mark each phase with its verification status.
8. **Known smoke-transform limits.** The smoke transform cannot parse `export type`, a single-line `() -> boolean` in a function head, `if`-expressions, or `::` casts on tables. Note these as limits; do not work around them in game code just for the harness.

## Known defects to look at
- The `multi_edit` luauCheck anomaly on `IslandConfig` and `FloatingObjectConfig`.
- `Lighting.Technology` read failure (edit mode). Do not read it.
- The `AmbientSea` one-shot timers should be re-checked after any change to `AmbientSea` (see `05`).
- The fishing `dm:"client"` probe ran as a server job once (see `06`).
- The `Boathouse` and `WoodenShip` ship issues (see `07`).
- The `Workspace.Part` slab is intentional. Do not delete it.
- The `WoodenShip` hover and the `Template` airborne hover (draft 0). Root cause undiagnosed.

## Acceptance criteria
- A1: The defect list has a status for every entry: fixed (commit), won't fix (reason), or open (owner and prompt).
- A2: No `Dbg*` attributes, no `REPORT_EVERY` other than 0, and no debug prints in the repo (except behind the Studio-only flag).
- A3: The repo checks pass (smoke 83 or more passed, 0 failed; syntax; project tree; `luau-compile` on every changed file).
- A4: `ROADMAP.md` and the docs match the verified state, with dates.
- A5: The user has a short list of the things they should try in Play, in order.

## Do not
- Do not change the design of any system in this pass. Polish means fixing defects, not redesigning.
- Do not delete `ServerBoat`, `Workspace.Part`, the fishing grab design, or the `AmbientSea` config.

## Deliverables
- `docs/audit/09-sweep.md`: the defect table with final statuses.
- Commits for each fix, and one commit for the doc updates.
- A final report to the user, with the PR link and the list of things to test in Play.
