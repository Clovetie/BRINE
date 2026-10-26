# Fishing rod: design notes

Studio: `Workspace.StickFishingRod` (Tool). Repo source: `BRINE/src/Workspace/StickFishingRod/`.

## Files
- `FishingServer.server.luau` (Script): cast, bobber physics, bite timing, catch, drag.
- `FishingClient.client.luau` (LocalScript): cast input, FishViewport + client Camera, drag input.
- `FishPose.luau` (ModuleScript): puts a fish's `BobberPos` on the bobber's `BobberPoint`.
- Fish: `ServerStorage.Fish.Common.Paralyseech` (Mball = PrimaryPart, Eyes union, BobberPos attachment).

## Rules
- Bobber: anchored, size 3 x 0.2 x 1 (never changed), no welds, no BodyMovers.
- Water physics on the bobber is scripted: a critically damped spring onto the sea surface
  (`WaveFloat.HeightAt`). Orientation is yaw-only, so there is no tilt, roll or sway.
  The viewport bobber is static.
- Rope: RopeConstraint between `RodLineAnchor` (anchored, follows the rod tip) and the bobber.
  Both ends are anchored, so the rope applies no force to the rod or the player.
- Bite: the viewport fish tweens so BobberPos meets BobberPoint. Text: "<Name> Bit bait!"
  on contact, then "<Name> Caught!" when the server confirms the catch.
- Caught: fish gets Caught and Dead attributes, Eyes set to black and SmoothPlastic, and is
  thrown behind the player. The bobber follows its BobberPos for CATCH_HOLD seconds, then returns.
- Drag: AlignPosition and AlignOrientation on the fish, driven by a server goal part.
  Range 22 studs, auto-release beyond 40.

## Status
- Build rebuilt in Studio after the autosave revert. Scripts pushed; Studio source lengths match the repo.
- Committed locally as `394d8fb` (not pushed).
- Edit-mode checks passed: FishPose puts BobberPos on the target (error 0.0000 at scales 0.8 and 1.3),
  body sits behind the mouth, WaveFloat sea height returns a value (24.46 at origin), bobber is 3 x 0.2 x 1,
  anchored, no welds.
- Server now answers every refused cast (Busy, TooClose, NoWater, NoCharacter). Client times out a cast
  after 15 s with no bite, so the rod can't get stuck.
- NOT playtested. Studio crashed and the user asked for no Play runs.
- Open for Play: rope renders with both ends anchored; rod Grip orientation; full cast -> bite -> catch -> drag.
- Known limit: the bobber still follows wave height vertically (damped). Fixing Y to sea level is one line if wanted.

## Sounds, particles, hook (round 3)
- Commit `e9bfc78` (local, not pushed).
- Rod location: the tool now lives in `StarterPack.StickFishingRod` (it had moved out of Workspace). Scripts pushed there.
- Sound IDs: `ReplicatedStorage.Fishing.FishingSounds`.
  Cast 86165035080520 (on the rod tip) · Took bait 9114452634 (contact) · Hook click 9113463271 · Caught 9118712043 (on the fish) · Bobber splash 9119481281 (landing, on the bobber).
  Dive: drops >= 10 studs -> 132575463084009 (loud). Smaller drops -> 92639900093467 or 100718358915709 at random, volume scaled by height. Under 1.5 studs: silent.
- Dive splash: `StarterPlayer.StarterPlayerScripts.DiveSplash`. Local player only. Skipped when seated.
- Hook flow: cast -> bobber lands (splash) -> bite wait -> viewport fish arrives (wriggles, bubbles) -> contact: "Took bait" sound, world bubbles, hook window 3 s -> one click = Hook -> "Caught!" -> fish splash + caught sound, eyes black/smooth plastic, thrown behind player.
  No click in 3 s: "It got away..."
- Wriggle: viewport fish swings side to side (0.6 studs, 14 degrees, 7 rad/s) from contact until caught or lost.
- Not yet verified in Play: audio asset permissions/loading, particle look, wriggle feel, hook window length.

## Round 4 (bobber orientation, wriggle, buoyancy)
- Bobber "changed" look: rest pose used `tip.WorldCFrame` (rod tip yaw 90 deg), flight and float used yaw 0. Rest pose and viewport clone now yaw-only identity. No code writes `Size`; Studio reads 3 x 0.2 x 1.
- Wriggle: starts on fish arrival (approachAlpha >= 0.999), not on the contact distance check. Swings yaw +/-30 deg at 8 rad/s about the bite point (mouth stays fixed; pivot math verified, error 0).
- Caught fish buoyancy (server): VectorForce spring to sea - 0.5 (K 6, D 5), horizontal drag 1.2/s, AlignOrientation upright (yaw only) while at or below sea + 3 and not dragged.
- Pushed: StarterPack.StickFishingRod.FishingServer (20828 chars, Studio hash 39199ebe); FishingClient (12405 chars, Studio hash 157acac9).
- Not yet tested in Play.

## Round 5 (float at the surface; MCP reconnect)
- MCP bridge reconnected to https://iowa-hampton-mothers-starring.trycloudflare.com/mcp (same token). `.mcp/call.py` and `probes/mcp_init.py` updated.
- Float problem: the spring (VectorForce) gave the fish a 1 to 1.2 stud swing around the surface, and it dove. Measured: the swell has 2.3 studs peak to peak and up to 1.5 studs/s vertical speed. Stiffer springs (K 60 and up) diverged at the real Heartbeat rate (0.008 to 0.065 s), with forces past 2e5 N. Physics spring dropped.
- New model: a thrown fish falls under physics. When it comes down onto the water (height <= sea + 1, falling) it is anchored and rides the surface: centre 0.5 studs below sea, yaw only, pivoted every frame. Drag unanchors it (AlignPosition); when the drag ends it rides again or falls.
- Sim (throw): landed, rel to surface -0.55 to -0.49 after landing (steady). Test: `probes/float_sm.lua`.
- Pushed: StarterPack.StickFishingRod.FishingServer (20703 chars, hash 2c4f9c8f). Commit 01f6b9d (local).
- Play restarted (server peer ready) so the new server is in use. Not yet tested with a real click.

## Round 6 (config, FloatingGui, reel-then-throw, grab, emitters, eyes)
- New `FishingConfig` ModuleScript in the tool (repo: src/Workspace/StickFishingRod/FishingConfig.luau). Every tuning value lives there: Cast, Bite, Catch, Float, Grab, Viewport, Gui.
- FloatingGui: `Workspace.FloatingGui` (ModuleScript, copied to src/Workspace/FloatingGui.luau). Client: ScreenGui parented to PlayerGui, then `FloatingGui.new(gui, Config.Gui)`; show/hide with `floating:Enable(bool)`; children read from `floating.SurfaceGui`.
- Catch: fish anchored, reeled along a smooth arc (ReelTime 1.1 s) to a hold point 1.5 studs in front of the player at 4 studs above the root (above the head). Released with ThrowBack 24 / ThrowUp 26 behind the player. The hold point follows the player, so it works on ships and high up.
- Clearance check (arithmetic): at the player's centre the fish is about 5.2 studs above the root, past the head.
- Grab: built-in AlignPosition/AlignOrientation. CanCollide off on all fish parts while held (captured and restored on release). Reeling fish cannot be grabbed (attribute Reeling).
- Emitters: the fish's ParticleEmitter (Mball) is disabled on catch (server clone and viewport clone).
- Eyes: UnionOperation.UsePartColor was false, so Color was ignored. Now set true, then black, SmoothPlastic.
- Bobber size: no code writes Size. A watcher was attached in Play (`_G.bobLog`, probes/bobber_watch.lua). Read it after a cast to confirm.
- Pushed: FishingConfig 86477e3e (79 lines), FishingServer 0a2d43e7 (767 lines), FishingClient 57c147f4 (459 lines).

## Round 7 (DragDetector grab)
- Grab is now Roblox's built-in DragDetector under the caught fish Model. ResponseStyle Geometric, DragStyle from Config.Grab.DragStyle (TranslateViewPlane: moves in a plane facing the camera, so the fish can be lifted). MaxActivationDistance = Config.Grab.Range (22).
- Geometric: the engine anchors the fish for the drag and restores physics on release. The server still sets Anchored itself on release (air: unanchored, water: anchored again).
- While dragged (f.dragging), updateFloaters skips the fish: no water spring, no reel. CanCollide stays off until release.
- Range: AddConstraintFunction clamps the held fish to Config.Grab.Range from the holder. Beyond that it stays at its last valid pose.
- DragDetector is disabled during the reel and enabled on release.
- Removed: AlignPosition/AlignOrientation grab, DragStart/DragMove/DragEnd remotes, client mouse-ray drag code, Grab.Leash/SendInterval/ForceMultiplier/Responsiveness.
- Pushed: FishingConfig (ModuleScript), FishingServer (719 lines), FishingClient (LocalScript) to StarterPack.StickFishingRod. Verified FishingServer by read-back.
- Not yet tested in Play with a real click.
