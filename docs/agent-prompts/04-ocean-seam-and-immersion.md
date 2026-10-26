# 04: Ocean seam, horizon, and underwater immersion

## Goal
The sea should look and feel continuous, from the shore to the horizon, and from the surface to underwater. Verify each piece with a probe where possible. The look itself needs the user's eyes.

## Current state
- **Outer edge seam.** The main wave plane follows the camera. It is 1872 studs wide and centred at (0, 25, 288) in the test world, so its edge is about 936 studs from the camera. The flat outer tiles (`SecondaryPlane`, 8 of them) sit at y = 25. Ring samples: max |dy| about 4 studs at 600 to 880 studs, and 2.7 to 3.4 studs at 900 to 960. The step at the edge moves with the waves.
- **Horizon haze (the current fix).** `SwimClient.client.luau` sets `Lighting.FogStart = 500` and `FogEnd = 880` on the client. This hides the edge. Visual check still owed.
- **Underwater murk.** `SwimClient` closes the fog over the first 3 studs below the surface (to `MURK_FOG_END` 120), uses a teal `MURK_FOG_COLOR`, and sets `SoundService.AmbientReverb` to `UnderWater` past 50 percent. Verified with a scripted camera: FogEnd 880 at the surface, 120 at depth, and back to 880.
- **Underwater tint and overlay.** `SwimClient` also has a `ColorCorrectionEffect` ("SwimTint") and a blue `ScreenGui` overlay. They run for any submerged camera, not only while swimming.
- **Splash.** `DiveSplash.client.luau` plays the dive splash (client only, not while seated, plus quieter variants at drop heights).
- **Sound.** `AmbientSea` (see `05`).

## Open questions
1. From below the surface, is the sea plane visible? Roblox mesh parts can be single-sided. If the plane is culled from below, the camera sees sky or the void through the water. Check in Play with the camera just under the surface looking up. The user should judge the look.
2. Does the horizon fog colour match the sky? The current colour is the default grey (0.75). Consider a sea-haze colour that matches the sky at the horizon.
3. A stronger fix for the edge is a world-fixed sea-state fade (flat beyond a radius), but that changes the wave field for gameplay too. Only do it with the user's approval. Note that `GetApproximateHeight`, `WaveFloat`, and `HeightLookup` all read the same field, so any change must keep them in step.
4. Does the murk fog affect islands and floating objects while underwater? It should, but check that objects still read correctly at 120 studs.

## Tasks
1. Measure the edge again with the current fog in place, using the same ring probe (`ocean/edge_check.lua`), and record what the fog hides (distance and fraction).
2. Check the underside of the sea plane (question 1). Record the result. If the plane is single-sided and culled from below, propose a fix (a double-sided underside plane, or a planar reflection-free underside colour) and wait for approval before implementing.
3. Check that the murk and horizon fog return to exact values after repeated dives (no drift). Use the scripted-camera check in `ocean/murk_check.lua`, split into probes under 15 seconds.
4. Check the splash and the underwater tint together. A dive should look like a dive: splash on entry, tint and fog closing in, reverb on, all in step.
5. Look for a regression in other fog users. Search the repo and Studio for `Lighting.Fog*` and `Atmosphere` writes. Only `SwimClient` should write fog.

## Acceptance criteria
- A1: The fog hides the edge at 880 studs and beyond (measured with the ring probe), and the horizon colour is recorded.
- A2: The underside of the sea is either verified visible from below or has a proposal awaiting approval.
- A3: Murk and horizon fog return to the exact surface values after 5 repeated dives (recorded).
- A4: One fog writer in the repo. Recorded.
- A5: The user has looked at the horizon and the dive in Play and confirmed, or has listed changes.

## Do not
- Do not change the wave field to hide the seam without approval (see question 3).
- Do not add a new fog writer. Route fog through `SwimClient` or a shared module that both read.

## Deliverables
- `docs/audit/04-immersion.md` with the numbers, the underside result, and the list of changes for the user to judge.
- Commits for any accepted fix.
