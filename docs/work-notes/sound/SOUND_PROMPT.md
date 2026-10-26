# Ocean sound prompt

## Goal
Add an immersive ambient sound bed to the sea, using the user-supplied asset IDs. Surface, underwater, wind, weather, and day/night all follow what the player sees and hears. This is the sound half of the immersion work. The ocean renderer and optimisation are not changed by this work.

## Tracks (user-supplied IDs)
| Role | ID | Notes |
|---|---|---|
| Surface calm bed (loop) | 78025480791776 | Soothing ocean waves |
| Surface beach layer (loop) | 137826155053556 | Ocean waves on beach, optional low layer |
| Surface rough layer (loop, 11 s) | 9120613130 | Rough waves, fades in with sea state |
| Underwater (loop) | 5033884807 | Underwater loop |
| Deep underwater (loop) | 94473522240855 | Deep underwater loop, fades in with depth |
| Wind bed (loop, 1:21) | 5799870105 | Ambient wind, scaled by sea state |
| Gust (one-shot) | 9118747859 | Wind howl, rough sea only, random |
| Birds (6 s one-shot) | 105990653889537 | Daytime, random |
| Night crickets (loop, 2 min) | 179507208 | Forest night ambience |
| Night wind (loop) | 6189441072 | Night wind |
| Cave (scary) | 273398061 | NOT used on the open sea; reserved for caves. Report only. |

## Constraints
- Keep existing behaviour: ships, swimming, fishing, floating, and the underwater tint and reverb.
- Leave the muted `Splash` loops on WoodenShip and Boathouse alone (volume 0 is the current state).
- Client-only sounds. Parent them under `SoundService` in a folder named `AmbientSea`, and create them on the client.
- Use `Sound.Looped` for loops, one-shots at random intervals.
- Each track must load. A track that fails to load is reported, not silently skipped.
- Volumes are mixed in code, with no magic numbers outside one config table.
- Sea state comes from `Gerstner.SeaStateAt(position, time)` (0.3 calm to 1 rough). Depth comes from the same surface test as SwimClient.
- No ocean renderer changes. No pushes to git. Studio pushes only for verification.

## Acceptance criteria
1. Every ID loads (IsLoaded and TimeLength > 0 in Play), or is listed as failed.
2. Surface: the calm bed plays; the rough layer and wind rise with sea state (verified by reading volumes at two points with different sea states).
3. Underwater (camera depth > 0): the surface beds fade out, the underwater loop plays, and the deep loop rises with depth (verified with a scripted camera at depths 0.5, 3, 8).
4. Back on the surface, the underwater sounds fall back to zero, with no stacking after repeated dives.
5. Night (Lighting.ClockTime 19–5): crickets and night wind on. Day: birds at random intervals. Verified by setting ClockTime in a probe and reading volumes.
6. Gusts appear only when the sea is rough. Verified by reading gust scheduling state.
7. Config is one table; the script compiles with luau-compile; the repo commit is local.

## Verification
- `ocean/sound_probe.lua`: loads every track on the client, reports IsLoaded, TimeLength, and Playing.
- `ocean/sound_check.lua`: scripted camera at depths and ClockTime values, reports volumes.
- Play restart via `ocean/restart_play.sh`. Client probes via `ocean/run_client.py`.

## Deliverables
- `src/StarterPlayerScripts/AmbientSea.client.luau` (new LocalScript).
- Local git commit.
- Short report with the list of tracks, what each does, which failed (if any), and which were left unused (cave).

## Results (Play, dm=client)
- Load: all 12 IDs load (`ocean/sound_probe.lua`). Lengths: beach 183 s, calm 143 s, calming 133 s, underwater 25 s, deep 7.4 s, rough 12.7 s, wind 80.5 s, birds 6.6 s, crickets 120 s, cave 118 s, night wind 88.5 s, wind howl 36 s.
- Calm surface, day: CalmBed 0.50 (full), Rough 0, Birds on. Pass.
- Rough surface, day: Rough 0.58, Wind 0.34, CalmBed 0.02. Pass.
- Depth 0.5 / 3 / 8: underwater 0.07 → 0.70 → 0.29 with deep 0.47; surface beds to 0. Pass.
- Return to surface: no underwater residue, surface beds back. Pass.
- Night (ClockTime 23): Crickets 0.35, NightWind 0.30, Birds 0. Pass.
- Gust: starts only at roughness ≥ 0.3 and not underwater. Rough point (192, 256), roughness 1.0: 1 start in the first window, then none while the 36 s gust played, as designed. Pass.
- Birds: 1 start per 11 s window in daytime at 0.25. Pass.
- Caveat: the sea-state field drifts over minutes (a point can go from 1.0 to 0.3). Tests scan for the current rough or calm point. Cave (273398061) unused on the open sea.
- Not verified: how the mix sounds to a listener. That needs ears on it; the volumes are the placeholder.
- Tool caveat: client RPC jobs time out after about 20 s, so long checks are split into short probes.
