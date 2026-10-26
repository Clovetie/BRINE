# Workspace.MisoSoup (ship) bounce fix

Reference: Workspace.ServerBoat (server-driven ship, same buoyancy model).

## Root cause
Main.Center (the hull's waterline reference, read as Center.WorldPosition.Y by
BoatManager/WaveFloat.Solve) was 6.7 studs ABOVE the hull centre on MisoSoup
(ServerBoat: 2.5 studs below). With the water surface about 25 studs, the
depth read about -0.4 to -0.5, right on WaveFloat's AIRBORNE_DEPTH = -0.5 gate.
The servo toggled MaxForce on and off every few tenths of a second, which
produced the ~0.5 s ringing (hull range 17 to 24 studs) while the sea itself
moved smoothly.

## Changes (Studio only; MisoSoup is not in the BRINE repo)
1. Workspace.MisoSoup.Main.Center: local position (0, 6.81, 8.43) -> (0, -0.98, 0),
   the hull bottom, below Main centre. Z zeroed so the reference stays on the
   centre line when the hull pitches.
2. Workspace.MisoSoup.VehicleSeat.BodyPosition.D: 800 -> 2840. This is ServerBoat's
   800 scaled by sqrt(AssemblyMass / ServerBoat AssemblyMass) (19565 / 1556).
   At 800 the hull jerked (0.1 s step 1.56 vs sea 0.85). 2840 matches ServerBoat's
   smoothness. 5600 was over-damped.
3. Workspace.MisoSoup.Handler: ServerBoat's Handler plus the seat offset. The goal is
   for the seat, which sits about 6.2 studs above Main on this hull. The offset is
   measured once at start (not per frame; per-frame re-measuring made the goal follow
   the bow's pitch and the hull dove). A DRAFT = 4 constant lowers the goal so the hull
   sits slightly submerged. Source: /home/user/miso/MisoSoup_Handler.luau
   (Studio hash b9feb396).
   Note: the "stock" reconstruction was not byte-identical to ServerBoat's
   Handler (94 vs 93 lines); the logic is the same.

## Verified (fresh Server Simulation run, D=2840, final config)
- Steady 4 s, 0.1 s sampling: hull max step 0.30, sea under hull max step 0.31.
- Hull minus surface at Main centre: mean +1.07, sd 1.43.
- ServerBoat, same run: mean +0.58, max step 0.33.

## Not done
- Studio edits are not saved to disk. Save the place in Studio to keep them.
- The MisoSoup fix is not in the git repo. No repo changes were made for it.

## Submerge pass (follow-up)
Measured against the corner-average surface the solver rides (12 s, settled run):
- MisoSoup: mean -1.09, sd 0.56 (range -2.1 to -0.2). Slightly submerged.
- ServerBoat: mean +0.66, sd 0.38.

### Submerge pass 2 (DRAFT 4 -> 6)
Requested: submerge MisoSoup a bit more. Studio `Workspace.MisoSoup.Handler`
`b9feb396` -> `c8e14e1c` (`DRAFT = 6`; `/home/user/miso/MisoSoup_Handler.luau`).
Server-only run, 12 s, corner-average surface:
- MisoSoup: mean -3.05, sd 0.36, min -3.68, max -2.23 (was -1.09 at DRAFT 4).
- ServerBoat: mean +0.70, sd 0.36 (unchanged).
Motion stays smooth (sd 0.36). To dial back, set DRAFT to 5 (about -2 studs).

### Submerge pass 3 (DRAFT 6 -> 7)
Requested: a bit deeper again. Studio `Workspace.MisoSoup.Handler` `c8e14e1c` -> `b3822547`
(`DRAFT = 7`). Server-only run, 12 s, corner-average surface:
- MisoSoup: mean -4.07, sd 0.35, min -4.65, max -3.42.
- ServerBoat: mean +0.68, sd 0.57 (unchanged).

## Ship guard port (this turn)

- Handler now uses ShipGuard (anti-climb, contact hold, floor, servo reserve) and the sea
  surface reference (surface + SinkRestOffset). The old goal-based reference fell with the
  hull. Backup of the pre-change Studio source: `miso/MisoSoup_Handler.before_sink_guard.luau`.
- Kept live tuning: DRAFT 7, SEAT_OFFSET logic, BodyPosition D 2840, Main.Center.
- `SinkRestOffset` = 2.4 (attribute on the MisoSoup model and the script constant). Measured
  rest after a 20 s settle: seat about +2.4 above the surface; Main about -4.
- Pushed as Studio hash 64b32e1f. Save the place in Studio to keep it.
- Results (server, unmanned):
  - 6x push, 20 s settle: rest -3.95, lowest -8.46 (drop ~4.5). Bobbing ±3 to ±9 studs/s.
  - 2x push (reference 1.4): rest about -4.6, lowest -6.8.
- Not solved: the velocity floor (ShipGuard lift) overshoots under sustained load. The
  next fix is an explicit VectorForce spring, the same as WoodenShip's open item.
