# 07: Ships and physics

## Goal
Every ship floats at the correct height, does not sink, does not climb onto things, drives like the reference, and survives a collision with the sea and other ships. `ServerBoat` is the reference. Do not change it.

## Files
- `src/Workspace/singletons/Ship/Handler.server.luau` (the shared ship handler)
- `src/Workspace/singletons/Ship/Client.client.luau`
- `src/ReplicatedStorage/ShipHandling/ShipGuard.luau` (anti-sink and anti-climb)
- `src/ReplicatedStorage/ShipHandling/ShipDrive.luau` (drive defaults)
- `BOAT_HANDLER.md`
- `ServerBoat` (reference; read only)
- Studio: `Workspace.Boat`, `Workspace.Boat1`, `Workspace.Boathouse` (a ship, not a building), `Workspace.WoodenShip`, `Workspace.MisoSoup`, `Workspace.Template`

## Current state (from the session notes)
- The new physics are on every ship except `ServerBoat`. `WoodenShip` has only the `SinkRestOffset` attribute (-2.0).
- Per-ship draft and sink values (measured in Play, 20-second settle):
  - `Boat` (reference): -2.78 / +0.13
  - `Template` at draft 5.9: -2.24 / +0.89. Draft 0 hovered in the air; the root cause is undiagnosed. Draft 5.9 is the workaround.
  - `Boat1` at draft 1.56: -2.97 / -1.95
  - `Boathouse` at draft 3.5: -3.32 / +1.99, **still bouncing**
  - `MisoSoup` at draft -7.3: -4.61 / +2.02. `MisoSoup` sits slightly submerged (DRAFT 7). `SINK_REST_OFFSET` is 2.4. The bounce fix applies to `Workspace.MisoSoup`, not islands.
- Guard config: `SinkMargin` 2.5, `ContactBand` 1.0, `SinkGain` 6, `MaxRise` 20, `ReserveGain` 1.5, `ReserveMax` 8.
- Settled sink with the reserve and the reference: `Boat` (6x push) settled at -2.15 (min -3.16). `WoodenShip` (RESP 12) settled at -0.68 (min -7.42). The `WoodenShip` minimum is poor: investigate.
- Ship-on-ship climb (guard on, 12 seconds): side control `Boat` 3.22, `WoodenShip` 3.35. Gap-4 results were inconsistent on rerun.
- Ship drive (live `Boat`): engine from rest 4.5 at 1 s, 20.3 at 4 s, 28.9 at 12 s. Coast from about 29: 24.4 at 1 s, 11.2 at 5 s, 5.7 at 10 s. Astern -9.7 at 8 s. Sail downwind 6.3, beam 18.1.
- Drive defaults: `EngineAccel` 8, `ReverseAccel` 2, `BrakeAccel` 8, `DragLinear` 0.08, `DragQuadratic` 0.0067, `LateralDamping` 1.2, `ThrottleSpool` 1.5, `MaxTurnRate` 0.5, `WindSpeed` 14, `SailAccel` 3.0, `LeewayRatio` 0.3.
- Hand-holding (keep): `MAX_LOOK_ANGLE_DEGREES` 360, `SPRING_STRENGTH` 4100, `PULL_DAMPING` 3600, `MAX_PULL_FORCE` 400000, `MAX_DISTANCE` 8, `OFFER_TIMEOUT` 3.

## Known issues to check
1. **Waves and ships.** The ship height reads the sea through `WaveFloat.HeightAt`. The rest-versus-displaced mismatch in `02` (S2) affects the ships too. Re-check ship draft after any change in `02`.
2. **`Boathouse` bounce** at draft 3.5. Diagnose before changing the draft.
3. **`WoodenShip` minimum sink** of -7.42. Diagnose.
4. **Template hover at draft 0.** Root cause undiagnosed. Keep draft 5.9 unless the root cause is found.
5. **Draft sign.** A larger draft lowers the hull. Use measured values.
6. **Reset.** Reset zeroes linear velocity. Zero `AssemblyAngularVelocity` too.
7. **MisoSoup legacy `BodyVelocity`** on the `VehicleSeat` holds horizontal velocity. Zero its `MaxForce` during a test and restore it after.
8. **Attributes and Play.** `SinkRestOffset` and handler code changes do not affect a running Play. A restart is required.
9. **The `Workspace.Part` slab** (Y 39.7) wedges the `WoodenShip` superstructure at its earlier spot. Do not test there.
10. **Climb.** Climb applies to all object types. Unanchored objects move aside. Fixed objects block. Obstacles must start 44 studs ahead of the `WoodenShip` main centre for probes.
11. **Collision-group pairs are global.** `PhysicsService` pairs are set in every handler. Check after a restart.
12. **Test blocks without water support** fall out of the world. Use an anchored platform.
13. **The user's rule:** "I'll fix the sink problem by not having platforms that aren't solid underneath." Do not add overhang-sink code for unsupported platforms.

## Tasks
1. Re-measure the draft and sink table for every ship, in one Play session, after the `02` fix (or before it, and again after). Record the table.
2. Diagnose `Boathouse` and `WoodenShip`. Propose a fix; implement the smallest one; re-measure.
3. Check that ship-on-ship climb and anti-sink still work with the current sea.
4. Check the drive numbers against the live `Boat` table above.
5. Make sure every ship except `ServerBoat` uses the same handler model, and document the one exception (`WoodenShip` attribute only).

## Acceptance criteria
- A1: The draft table is re-measured and recorded for every ship.
- A2: `Boathouse` settles without bounce (define a threshold, e.g. max vertical speed below 0.2 studs per second after 20 seconds, and record it).
- A3: The `WoodenShip` minimum sink is recorded and reduced, or the reason is recorded.
- A4: `ServerBoat` has no diff from `main` in this branch.
- A5: The climb and anti-sink results are recorded with the same settings as before.

## Do not
- Do not change `ServerBoat`.
- Do not change the drive or guard values without a recorded reason.
- Do not add overhang-sink code.

## Deliverables
- `docs/audit/07-ships.md`: the tables and the diagnoses.
- Commits for fixes.
