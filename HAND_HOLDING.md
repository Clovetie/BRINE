# Hand-Holding System (R15 + IKControl)

A simple, player-hosted hand-holding interaction for R15 characters.

- Player presses `L` once while facing a nearby player to offer/accept.
- Player presses `L` again to release; `L` is a **toggle**, not a hold key.
- When both players have toggled on and the server accepts the interaction,
  each character receives an independent, horizontal `VectorForce` spring.
  Players can walk separately and are pulled toward each other only after the
  tether's rest distance is exceeded.
- `IKControl` is used only to pose the arms toward the midpoint; no constraint
  joins the two character assemblies.
- Releasing `L`, dying, respawning, leaving, or moving too far apart breaks the
  connection.

The **server is authoritative** for all state. The client only tells the server
when `L` is pressed/released and which player it is targeting.

---

## Explorer hierarchy

```
ReplicatedStorage
└── HandHolding [Folder]
    ├── HandHoldingConfig [ModuleScript]
    └── HandHoldingEvent [RemoteEvent]

ServerScriptService
└── HandHoldingServer [Script]

StarterPlayer
└── StarterPlayerScripts
    └── HandHoldingClient [LocalScript]
```

## Files / locations / types

| Explorer path            | Type          | File on disk |
| ---                      | ---           | --- |
| `ReplicatedStorage.HandHolding.HandHoldingConfig` | ModuleScript | `src/ReplicatedStorage/HandHolding/HandHoldingConfig.luau` |
| `ReplicatedStorage.HandHolding.HandHoldingEvent` | RemoteEvent | `src/ReplicatedStorage/HandHolding/HandHoldingEvent.model.json` |
| `ServerScriptService.HandHoldingServer` | Script | `src/ServerScriptService/HandHoldingServer.server.luau` |
| `StarterPlayer.StarterPlayerScripts.HandHoldingClient` | LocalScript | `src/StarterPlayerScripts/HandHoldingClient.client.luau` |

`default.project.json` maps the Rojo tree so these instances appear at exactly
those paths.

---

## Client-to-server protocol

`HandHoldingEvent` is a single `RemoteEvent`. The client sends:

| Payload | Meaning |
| --- | --- |
| `("PressL", targetPlayer)` | The local player toggled hand-holding on and intends to interact with `targetPlayer`. |
| `("ReleaseL")` | The local player is no longer holding `L`. |

The client may send `nil` as the target when nobody is nearby. The server
ignores the target if it is not a valid `Player`, not in range, already busy,
or if the event is otherwise stale.

The client never sends distance, connection state, or accept state.

---

## State model

```
Idle -> Offering -> Accepted -> Holding -> Released/Cancelled
```

| State | Server representation |
| --- | --- |
| `Idle` | No entry in `offers` and no entry in `connectionByPlayer`. |
| `Offering` | `offers[offerer] = { target, token }` |
| `Accepted` | Exists only as a step during a mutual offer; immediately transitions to `Holding`. |
| `Holding` | `connectionByPlayer[a] = connectionByPlayer[b] = { ... }` |
| `Released` | `connection.ending = true`; IK weight fades out, then the connection is destroyed. |

The state is authoritative on the server. The client has no state machine.

---

## How target selection works

The client picks a target when `L` is first pressed:

1. It reads the local character's `HumanoidRootPart`.
2. For every other player it checks the distance from the local
   `HumanoidRootPart`.
3. It keeps only players within `MAX_DISTANCE` (default `8` studs).
4. It keeps only players inside a cone in front of the player's facing
   direction (`MAX_LOOK_ANGLE_DEGREES`, default `110°`).
5. It scores each remaining player by how close they are and how centered they
   are in the cone, then picks the best one.

The client's choice is only a **hint**. The server re-validates the real
distance, character state, R15 rig, and busy status.

---

## How the two-player acceptance works

1. Player A presses `L` once. The client fires `("PressL", B)`.
2. The server checks that both players are valid R15 characters in range and
   that neither is already holding hands. It stores `offers[A] = { target = B }`.
3. Player B presses `L` once. The client fires `("PressL", A)` (or whatever
   target B picked).
4. The server sees that **A is already offering to B**. That is the
   acceptance: B toggled on and chose A. The server establishes the physical
   connection and clears both offers.
5. If A is not already offering to B (e.g. only B offered), then B simply
   creates an offer, and A's later press completes it the same way.

This makes simultaneous offers naturally converge: regardless of which press
event arrives first, the second press sees the mutual offer and establishes the
connection.

---

## How connection establishment works

On a mutual offer the server:

1. Re-validates both players are valid R15 and alive.
2. Re-checks the distance between their `HumanoidRootPart`s.
3. Picks the closest hand pair: `A.LeftHand`/`A.RightHand` vs
   `B.LeftHand`/`B.RightHand`.
4. Creates an `IKControl` for each selected hand and targets the midpoint
   between the hands.
5. Adds equal/opposite horizontal spring forces to each character root once
   they exceed `REST_DISTANCE`; the assemblies remain independent.
6. For each side it creates an `IKControl`:

   ```lua
   ik.Type = Enum.IKControlType.Position
   ik.EndEffector = character:FindFirstChild(side .. "Hand")
   ik.ChainRoot  = character:FindFirstChild(side .. "UpperArm")
   ik.Target     = attachment
   ik.SmoothTime = 0.12
   ik.Weight     = 0
   ik.Enabled    = true
   ik.Parent     = character:FindFirstChildOfClass("Humanoid")
   ```

7. Attachment targets are parented to each `HumanoidRootPart` and updated
   every frame to the **midpoint between the two selected hands**.
8. IK weight blends from `0` to `1` over `IK_FADE_TIME`.
9. When either player releases `L`, the connection is marked `ending`, the
   logical state is cleared immediately, and the weight blends back to `0`
   before the IK controls and collision filters are destroyed.

---

## Server validation

The server validates, on every relevant event/frame:

- Both players still exist (`Player.Character`).
- Both characters have an alive `Humanoid` with
  `RigType == Enum.HumanoidRigType.R15`.
- Required R15 parts exist.
- The target is actually within `MAX_DISTANCE`.
- Neither player is already in an active hand-holding connection.
- The target is a valid `Player`, not the same as the offerer.
- The offer has not expired (`OFFER_TIMEOUT`).
- The target's character is still valid.

Client-supplied distance, connection state, or acceptance state is never
trusted.

---

## Edge cases

| Case | Handling |
| --- | --- |
| 1. Press `L` with nobody nearby | Client fires `("PressL", nil)`. Server treats it as a normal press with no valid target and cancels any existing offer. |
| 2. Release before target accepts | Client fires `("ReleaseL")`; server removes the offer. |
| 3. Target accepts after offer expires | The old offer is removed by `task.delay`/cleanup; the new press creates a fresh offer instead of silently accepting a stale one. |
| 4. Both players offer simultaneously | Mutual-offer detection connects them regardless of event order. |
| 5. A offers to B while B is holding C | `getActiveConnection(B)` returns the active connection; A's offer is not created. |
| 6. A tries to accept while already holding | The player's own active connection blocks them; `getActiveConnection(A)` rejects the new offer. |
| 7. Players move out of range | Heartbeat re-checks distance and force-drops the connection. |
| 8. Death / respawn | `CharacterRemoving`, `CharacterAdded`, and heartbeat all force-drop the connection and clear offers. |
| 9. Leaving | `PlayerRemoving` cleans up the connection and cancels offers targeting the player. |
| 10. Character changes / temporarily unavailable | Same as death: cleanup on character events plus per-frame re-validation. |
| 11. Rapid press/release | A fresh press while a previous connection is still fading out force-drops the old IK before creating a new offer. |
| 12. Network latency / out-of-order events | The server is synchronous and authoritative. Different players' events converge through mutual-offer detection; same-player events are processed in send order. |
| 13. Two players offer to the same target | Only the target's selected offer is accepted; `cancelOffersToPlayer` clears all other offers to that player on establishment. |
| 14. Target changes before accept | The server only accepts an offer whose current `offers[target]` matches the presser; otherwise it creates a fresh offer. |
| 15. Missing IK/target parts | `createIkSetup` returns `nil` if any R15 chain part is missing; establishment fails safely. |
| 16. Non-R15 | `isValidR15Character` rejects anything that is not a valid R15 character. |
| 17. Animation vs IK | The IK control owns the chain between the upper arm and hand. Its `Weight` is faded in/out and `Enabled` is managed by the server to avoid fighting the default animation. |
| 18. Players turn/move while holding | The character assemblies remain independent. Equal/opposite horizontal spring forces pull them together only beyond `REST_DISTANCE`; the midpoint targets keep the hand pose aligned. |

---

## How to use in Studio

1. Add the files to a Rojo project or copy the hierarchy manually.
2. Make sure all characters are R15.
3. Use two players in the same server.
4. Each player presses `L` once while facing the other (within `8` studs).
5. Press `L` again to release the physical connection.

`MAX_DISTANCE`, `MAX_LOOK_ANGLE_DEGREES`, `OFFER_TIMEOUT`, fade times, and IK
smoothing are all centralized in `HandHoldingConfig`.

---

## Tooling

`tools/` contains reusable checkers/format configs for this repo:

```bash
bash tools/setup-tools.sh
node tools/check-syntax.js
```
