# 06: Fishing

## Status
The user accepted the fishing test as "Normal" (session end). The fishing work is in the repo now (commit on this branch), but several items were implemented and only partly tested. This prompt is a regression audit plus the open items. Do not redesign the system without the user's approval.

## Files
- `src/Workspace/StickFishingRod/FishingServer.server.luau` (grab, bite, catch, sounds, server state)
- `src/Workspace/StickFishingRod/FishingClient.client.luau` (UI, viewport, input)
- `src/Workspace/StickFishingRod/FishingConfig.luau` (tuning, including `HOOK_WINDOW` 3 seconds)
- `src/Workspace/StickFishingRod/FishPose.luau`
- `src/ReplicatedStorage/Fishing/FishingSounds.luau`
- `src/StarterPlayerScripts/DiveSplash.client.luau`
- `docs/work-notes/fishing/NOTES.md` (rounds 5 and 7 are the most recent)
- Studio: `StarterPack.StickFishingRod`. `Rod` children are `FishingRodTip`, `Bobber`, `Line`, and `RopeConstraint`. The UI is `FishingRodUI` > `Background` > `FishingReactive` (TextLabel) and `FishViewport` (ViewportFrame). `ServerStorage.Fish.Common.Paralyseech` is a common fish.

## Requirements (from the user, in their words where possible)
1. **Grab uses DragDetector.** The user explicitly replaced the custom AlignPosition and AlignOrientation grab with a DragDetector ("it's built in and way better"). CanCollide stays off while held.
2. **Caught fish: floating physics off while held.** The caught fish's floating physics are off while the player holds it.
3. **Rope physics do not affect the player.** The player is affected by normal physics only.
4. **Paralyseech is one of the common fish** in `ServerStorage`.
5. **Client-side camera for the viewport.** A client camera drives `FishViewport`.
6. **Dead Paralyseech eyes.** If Paralyseech is dead, the eyes union turns black and becomes SmoothPlastic.
7. **Viewport is the main focus of the UI.** Bite and catch text uses `FishingReactive`.
8. **Bite feedback.** Particles show and the fish wriggles back and forth on a bite. One click is enough for now. The mash system comes later.
9. **Sounds (user's IDs):** rod cast `86165035080520`; fish took bait `9114452634`; player clicks to catch `9113463271`; caught fish `9118712043`; bobber water contact `9119481281`. General: dive splash `132575463084009` (only when not seated); the same splash, quieter, `92639900093467`, played at varying drop heights; `100718358915709` is a random quiet variant.
10. **Caught fish stays at the water surface.**
11. **Reel-in model** (from the design notes): the grabbed fish moves in an arc to a hold point in front of the player at chest height, then releases with a back-and-up velocity. Floating is skipped while held. Bite: `BobberPos` meets `BobberPoint`. The caught fish is tagged `Caught` and `Dead`. Bait is taken on contact, then one click within 3 seconds (`HOOK_WINDOW`) catches. A miss sends `GotAway`.

## Known issues and open points
- The fishing float model was superseded (`01f6b9d`). Check that no float code path is still active.
- Studio autosave once reverted the first build and moved the rod from `Workspace` to `StarterPack`. Do not push to `Workspace.StickFishingRod`.
- The `dm:"client"` probe sometimes runs as a server job. Use `LocalPlayer` in the output to confirm.
- `RopeConstraint.Color` needs a `BrickColor`.
- Refused casts once left the client stuck in "Catching...". Fixed with Busy, TooClose, and NoCharacter cancel replies plus a 15-second client timeout. Check the timeout still fires.
- The wriggle was once invisible (gated on 0.6-stud contact at 14 degrees). It was fixed in the repo but has not been re-tested. Test it.
- Sounds are played server-side on the bobber, rod tip, or fish; the dive splash is client-only. Confirm no sound is played twice.
- Drops of 10 studs or more use the loud sound. Confirm the threshold.

## Tasks
1. **Regression audit.** Go through each requirement above. For each one, record: implemented (where), tested (how), result. Mark anything untested.
2. **Play test.** Cast, bite, click within the window, catch, and release. Repeat with a miss (GotAway) and with a cast that is refused.
3. **Fix what fails**, one item at a time, with the smallest change.
4. **Check the sounds.** Confirm each ID resolves in Play (`IsLoaded` and `TimeLength` > 0), and confirm volumes and playback once per event.
5. **Check the camera.** The viewport camera must not change the player's camera.

## Acceptance criteria
- A1: Every requirement above has a recorded status.
- A2: The Play test passes for cast, bite, catch, GotAway, and refused cast, with the results recorded.
- A3: No client-side camera or input change leaks to the server.
- A4: The user confirms the feel in Play (the wriggle, the particles, the sounds).

## Do not
- Do not change the grab back to AlignPosition or AlignOrientation.
- Do not change the DragDetector settings without a reason recorded.
- Do not push to `Workspace.StickFishingRod`.
- Do not implement the mash system (later).

## Deliverables
- `docs/audit/06-fishing.md`: the requirement table with statuses and the Play results.
- Commits for fixes.
