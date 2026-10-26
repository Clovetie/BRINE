# 08: Floating objects and islands

## Goal
Floating objects and islands should be sparser, less compacted, and less periodic. They should float at the correct height, stay in place for the player who can see them, and never disappear while in sight.

## Files
- `src/ReplicatedStorage/FloatingObjectGeneration/` (generator, config, Density, `WaveFloat.luau`)
- `src/ReplicatedStorage/IslandGeneration/` (Density, Placement, IslandGenerator, IslandConfig)
- `src/ServerScriptService/FloatingObjectGenerationServer.server.luau`
- `src/StarterPlayer/StarterPlayerScripts/FloatingObjectsClient.client.luau`
- `src/ServerScriptService/HandHoldingServer.server.luau` and `src/ReplicatedStorage/HandHolding/HandHoldingConfig.luau`
- `tools/smoke/tests.lua` (floating sections)
- Studio: the same modules, plus any leftover debug hooks

## Requirements (user's)
1. **Density and activation.** Sparser, less compacted, and less periodic islands and floating objects.
2. **Ring plus range** for floating objects (activation by a ring and a range around the player).
3. **Physics.** Small and Medium objects both float too low. Raise the float ratio. The user will test later.
4. **No despawn in sight.** Floating objects must not despawn or be removed while in a player's sight. This applies to every path: cull, lifetime, and the Unseen cache.
5. **Keep work, float unmanned.** Objects float without a player.
6. `MaxCachedRecords` = 3000 (keep).

## Current state (from the session notes)
- Density (n = 1681): mean 0.47. The nearest ring or range value was 207.3 studs.
- FloatRatio: Large (Frozen) 0.371, Medium (Frozen) 0.311, Small (Buoyant) 0.290 (n = 16). Buoyant Small pooled: 0.3 gives 0.300, 0.6 gives 0.295, 0.8 gives 0.356. The user asked to raise the ratio for Small and Medium. The live value is `FloatRatio` 0.6 (restored) unless it was changed in Studio; check.
- Responsiveness: 12 (restored from 30). `SoftResponsiveness` 24 was tried; it made servo lag worse, and it was not reverted in Studio. Confirm the repo value.
- Integral action (gain 0.3) did not change the settled ratio.
- Objects are mostly Frozen when the player is away. `NearBandStuds` = 150 did not wake a full population.
- Float height from per-object bounding boxes is noisy. Use the mean water height (about 24.98) over many XZ points and times.
- The cull fix (`args_fgen_sight.json`) was pending when the session ended. Confirm it is in the repo.

## Known issues to check
1. **Repo versus Studio.** Several edits were made in Studio first (`IslandGeneration.Density`, `Placement`, `IslandGenerator`, `IslandConfig`, `FloatingObjectConfig`, `FloatingObjectGenerator`). Read each one back and compare with the repo.
2. **Leftover debug hooks** in `FloatingObjectGenerator`: `args_gen_dbg_on` (30ef92c1) and `args_gen_dbg_fix` (62503b5c). Remove them if they are still there, and record it.
3. **Hook placement.** A debug hook placed after the `targetY == nil` early return never fires. Place hooks before early returns.
4. **Smoke harness.** The `FloatingObjectGenerator` line 75 crash (missing `Density` bundle entry) was fixed. Do not revert it.
5. **`math.noise`** does not exist in the smoke runtime (Fengari). The harness uses a deterministic stand-in. Keep it.
6. **`multi_edit` luauCheck** returned `ok=false` with empty compile errors on `IslandConfig` and `FloatingObjectConfig`. Re-check both with `luau-compile`.

## Tasks
1. Read back every floating and island module from Studio and diff against the repo. Record the result.
2. Remove the debug hooks, and set the float ratios and responsiveness to the agreed values (see the requirements). Record each value before and after.
3. Confirm the no-despawn-in-sight rule on all three paths (cull, lifetime, Unseen cache). Write a probe that places an object in the player's view and checks it is still present after a full lifetime and cull cycle.
4. Re-measure the density and the nearest ring distance.
5. Measure float height for Small and Medium objects at the new ratio, and record it.

## Acceptance criteria
- A1: Repo and Studio match for every floating and island module (read back, recorded).
- A2: No debug hooks in Studio or the repo.
- A3: The no-despawn-in-sight probe passes on all three paths.
- A4: Small and Medium objects float at the target height (define it with the user; the current mean water height is about 24.98).
- A5: The smoke test still passes (83 passed, 0 failed, or more with new tests).

## Do not
- Do not raise `MaxCachedRecords` above 3000 without approval.
- Do not add a despawn path that ignores the sight check.
- Do not change the hand-holding values (keep as listed in `07`).

## Deliverables
- `docs/audit/08-floating.md`: the read-back diff, the values before and after, and the probe results.
- Commits for fixes.
