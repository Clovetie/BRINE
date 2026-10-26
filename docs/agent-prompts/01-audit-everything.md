# 01: Audit everything

## Goal
Produce an honest inventory of the game: what exists in the repo, what is live in Studio, what is dead, what disagrees, and what is broken. This prompt finds problems; the later prompts fix them. Do not fix things in this pass unless they are trivially safe and you record them.

## Inputs
- Repo: `/home/user/BRINE` (branch `arena/ocean-sound-and-audit`).
- `ROADMAP.md`: the phase list. Phases 0 to 3 done (3.4 retired), 4.1, 4.2, 4.4 done, 4.3 partial, 5.1 and 5.3 done, 5.2 won't do, 6.1 verified, 6.2 partial, 6.3 to 6.10 marked done but not re-verified. Phase 7 is pending playtest.
- `tools/call-graph.js`, `tools/find-dead-config.js`, `tools/validate-project.js`, `tools/smoke-test.js`, `tools/check-syntax.js`.
- `default.project.json`: the Rojo-style mapping from `src/` to Studio.

## Tasks
1. **Repo health.** Run the checks in `00-README.md`. Record the output. Run `tools/find-dead-config.js` and `tools/call-graph.js`. List every module that is required by nothing, and every config key that is read by nothing.
2. **Repo vs Studio parity.** For every file in `src/` that has a Studio counterpart, read it back (`bridge/get_src.py`) and diff it against the repo. Record each mismatch. Known risk areas: the ocean (`Gerstner`, `OceanParallel`, `Setup`), `AmbientSea`, `SwimClient`, `StickFishingRod`, ship handlers (`Boat`, `WoodenShip`, `Template`, `Boat1`, `Boathouse`, `MisoSoup`), and `FloatingObjectGeneration`.
3. **Studio leftovers.** Record any debug hooks or temporary attributes still in Studio. Known ones from the session: floating debug hooks `args_gen_dbg_on` (30ef92c1) and `args_gen_dbg_fix` (62503b5c), plus `SoftResponsiveness` 24 on floating objects (not reverted), and `args_miso_noguard_on` (d45cda38, not reverted). Also check for `DbgTicks`, `DbgWait`, `DbgRough`, `DbgUnder` attributes on `SoundService.AmbientSea` objects (these should not exist in the current build).
4. **Muted or silent assets.** `Workspace.WoodenShip.Prim.Splash` and `Workspace.Boathouse.Prim.Splash` are looping sounds at volume 0. Find every `Sound` in the workspace and record its ID, volume, and play state. Note any ID that Studio warns is not approved (for example 167123203 and 203785492; check whether those are ours before deciding anything).
5. **Asset warnings.** Read the console for `failed due to` warnings and list each asset ID and the object that uses it.
6. **Scripts that run on the wrong side.** For each server script, check that it does not touch `LocalPlayer` or `CurrentCamera`. For each client script, check that it does not change replicated state.
7. **Remote and event names.** Check every `RemoteEvent` and `RemoteFunction` name against its use. List any name used on one side only.
8. **Tool and documentation drift.** `BOAT_HANDLER.md`, `SWIMMING.md`, `ROADMAP.md`, and the notes in `docs/work-notes/` should match the code. List every claim that does not.

## Acceptance criteria
- A written inventory at `docs/audit/01-inventory.md` with one table per area: file, repo status, Studio status (match, differs, missing), dead or unused (yes or no), and the next action.
- A defect list at `docs/audit/01-defects.md`. Each defect has an ID, a severity (P0 breaks play, P1 visible wrong, P2 polish, P3 debt), the file or Studio object, the evidence, and the prompt that should fix it.
- Every number in the inventory is backed by a command or a read-back. No guessed numbers.

## Verification
- Re-run the repo checks after writing the audit docs. They should still match the baseline.
- Spot-check five random defects against the source to confirm they are real.

## Do not
- Do not change game behaviour in this pass.
- Do not push to Studio except to read.
- Do not delete `Workspace.Part`, `ServerBoat`, or the sound folder.

## Deliverables
- `docs/audit/01-inventory.md`, `docs/audit/01-defects.md`, and a commit with only the audit documents.
