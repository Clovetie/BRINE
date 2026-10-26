# 05: Ambient sea sound

## Goal
The ambient sea sound should match what the player sees and hears, follow the sea state, depth, and time of day, and never stack or get stuck. The mix needs a listener's judgement. Get that from the user.

## Current state
- `src/StarterPlayerScripts/AmbientSea.client.luau` (commit `c27dd3b`). Client only. A folder `SoundService.AmbientSea` holds 10 sounds: 8 loops and 2 one-shots (gust and birds).
- The mix is driven from the camera every Heartbeat: sea state (`Gerstner.SeaStateAt`) gives roughness, `WaveFloat.HeightAt` gives depth, and `Lighting.ClockTime` gives day or night. Volumes move toward targets at `FadeRate` 1.5 per second.
- The config is one table at the top of the script (`CONFIG`): track IDs, full volumes, fade rate, depth bands, timer intervals, and clock hours.
- Track IDs (all 12 user-supplied IDs load in Play):

| Role | ID | Used |
|---|---|---|
| Calm bed | 78025480791776 | yes |
| Beach layer | 137826155053556 | yes |
| Rough waves | 9120613130 | yes |
| Underwater | 5033884807 | yes |
| Deep underwater | 94473522240855 | yes |
| Wind bed | 5799870105 | yes |
| Wind howl (gust) | 9118747859 | yes |
| Birds | 105990653889537 | yes |
| Night crickets | 179507208 | yes |
| Night wind | 6189441072 | yes |
| Calming ocean waves | 131586509457092 | **no** (similar to the calm bed; ask the user) |
| Cave ambience (scary) | 273398061 | **no** (reserved for caves; there are none yet) |

- Verified in Play (see `docs/work-notes/sound/SOUND_PROMPT.md`, Results): volumes for calm and rough surface, depths 0.5, 3, and 8, return to surface, and night. Gusts start only on rough water, and not while a gust is playing. Birds start in daytime at 0.25.
- Not verified: how the mix sounds to a listener.

## Known issues to check
1. **Sea-state drift.** The sea-state field drifts over minutes. Checks must scan for the current calm or rough point right before a test, or the test measures the wrong thing. This was the cause of several false negatives.
2. **Client RPC limit.** Client probes time out after about 20 seconds. Keep each under about 15 seconds.
3. **Surface beds at shallow depth.** At depth 0.5 the surface beds are still at about 83 percent. Decide whether that is wanted.
4. **The muted splash loops.** `Workspace.WoodenShip.Prim.Splash` and `Workspace.Boathouse.Prim.Splash` are at volume 0. These are ship sounds. Do not change them without the user's approval. Note that the ambient sea loops are in `SoundService`, not the workspace.
5. **Asset warnings.** Studio warns about IDs 167123203 and 203785492 (not approved; asset type mismatch). Check whether either is used by a sound that matters.
6. **Cave ambience.** Unused. If the user wants caves, the cave should be a separate zone with its own volume rule. Do not use it on the open sea.
7. **Gust and birds timers.** Both are random-interval `task.spawn` loops. Check that they stop cleanly when the character is removed or the script is reloaded.
8. **Time-of-day.** `Lighting.ClockTime` is read on the client. Check that a server-side time change is picked up.

## Tasks
1. Ask the user to listen in Play and report: is the calm bed too loud, is the rough layer too sharp, is the underwater change too abrupt, do the birds and crickets feel right? Use the user's answers to set the config values.
2. Decide on the calming track (131586509457092) with the user. Options: a second calm bed alternated on a timer, a layer at low volume, or unused.
3. Add a guard so the one-shot timers do not run before the character spawns, if they do now.
4. Confirm there is no duplicate `AmbientSea` folder after a character respawn or a Play restart (the folder count was 1 in the last check).
5. Write down every value in `CONFIG` that was a guess, so the user can tune them.

## Acceptance criteria
- A1: The config changes the user asked for are in, each with the reason.
- A2: The checks from `SOUND_PROMPT.md` still pass after any change. Re-run them.
- A3: No duplicate sounds, no stuck volumes, no leaked timers after a respawn (record the check).
- A4: The calming track and the cave track have a decision recorded.

## Do not
- Do not change the ship's splash loops.
- Do not invent sound IDs. Use only the IDs the user has supplied, or ask.
- Do not make the sound depend on the ocean renderer's internals. It should read only `SeaStateAt`, `HeightAt`, and the clock.

## Deliverables
- Commits for the config and logic changes, each with the user's note or the check result.
- A short list for the user: the values to tune by ear.
