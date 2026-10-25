# Swimming (R6 and R15)

Players can swim in the sea. Once the character sinks below the wave surface with
nothing solid underneath, it swims. Swimming uses the same physics as the floating
objects and ships: the same analytic wave field, a spring to the surface, and a tilt
that follows the local slope.

## Files

- `src/ReplicatedStorage/Swimming/SwimModel.luau`: the pure model (depth, enter and
  exit with hysteresis, the spring, desired velocity, easing, tilt, tint strength).
  Covered by `tools/smoke/tests.lua`.
- `src/StarterPlayerScripts/SwimClient.client.luau`: the controller. It samples the
  waves, raycasts for floor, writes the character's velocity and orientation, reads
  input and drives the underwater tint.

## Behaviour

- **Entering.** The root must be more than `EnterDepth` (1 stud) below the surface, with
  no solid floor within 4 studs. The raycast ignores non-collidable parts, so the sea
  mesh (`CanCollide = false`) does not count as floor.
- **Floating.** The root is pulled toward the surface with a spring (`SpringGain`), and
  it follows the crests and troughs. Gravity is cancelled with a `VectorForce`.
- **Tilt.** The body takes `TiltFactor` of the local wave slope, capped at `MaxTilt`
  (25 degrees), with yaw turned toward the swim direction.
- **Controls.** WASD swims in the camera's direction, including up and down when the
  camera looks that way. Space rises, and Left Ctrl or Left Shift dives. Releasing the
  dive keys lets the swimmer rise back to the surface.
- **Leaving.** The swimmer leaves the water above `ExitDepth` (2 studs), or when it
  reaches solid ground. A seat (a ship) or death also ends the swim.
- **The void.** There is no floor under the sea, so a diver can keep going down.
- **Tint.** As the camera goes under the surface, the view tints blue (a
  `ColorCorrectionEffect` plus a translucent blue overlay), reaching full strength
  `TintFullDepth` (10 studs) below.

## Limits

- Keyboard only. There are no touch or gamepad controls yet.
- Physics belongs to the local player, so the forces replicate like normal movement.
  Other clients see the swimmer through replication, not through their own controller.
- The R6 and R15 paths use the same code, which only touches `Humanoid` and
  `HumanoidRootPart`. Live testing on R6 has not been done yet.
