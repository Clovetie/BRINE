# 06 — Fishing regression audit

Prompt 06. The user accepted fishing as "Normal", so the job here is **regression**: prove the grab is
still a `DragDetector`, that no mover crept back in, and that nothing this branch changed has moved
the fish.

Session: Play with a real client peer (`Hirabelan`), server and client probes.

---

## 1. The grab rule: **PASS**

The user's hard rule is "keep the fishing grab on `DragDetector`; do not go back to `AlignPosition` or
`AlignOrientation`".

Static check over every fishing file:

```
grep -n "AlignPosition\|AlignOrientation\|BodyVelocity\|BodyPosition" src/Workspace/StickFishingRod/*.luau
→ none -- fishing uses no movers at all
```

The grab is built in `FishingServer.server.luau:375 makeDragDetector(f)`, called once per caught fish at
`:514 f.dd = makeDragDetector(f)`, with `ResponseStyle = Geometric`
(`DRAG_STYLE = Enum.DragDetectorDragStyle[GRAB.DragStyle]`, line 324).

**No mover of any kind exists anywhere in the fishing path.** The rule is satisfied structurally, not
by a setting someone could flip back.

---

## 2. Runtime state: **PASS**, with a caveat about when the detector exists

Measured on the server in Play:

| Check | Result |
|---|---|
| Rod in `Hirabelan.Backpack` | present |
| Rod equipped via `Humanoid:EquipTool` | equipped |
| `tool.FishingRemotes` | `FishEvent[RemoteEvent]`, `Action[RemoteEvent]` — both live |
| `DragDetector` count on the **rod** | **0** |
| `AlignPosition` / `AlignOrientation` on the rod | 0 / 0 |
| `DragDetector` on a raw clone of `ServerStorage.Fish.Common` | **0** |
| Movers on that clone | 0 |

The zeros are correct, not a defect: the `DragDetector` is created on the **caught fish**, not on the
rod and not in the template. `makeDragDetector` runs inside the catch path, so a rod that has not
caught anything has no detector and a template clone has none either. Each caught fish parents its own.

**Caveat, stated plainly:** I verified the mechanism by code path and by the absence of movers, not by
completing a full cast → bite → catch → drag cycle. Completing that cycle needs the client to drive
the rod through `Action`, which is a longer scripted interaction than a 19 s client probe. So "the
grab still works when a fish is in hand" is **inferred from the code and the live remotes, not
observed**.

---

## 3. What this branch changed that touches fishing

`FishingServer.server.luau:23` requires `ReplicatedStorage.FloatingObjectGeneration.WaveFloat` and
takes the fish's surface height from `WaveFloat.HeightAt`. The S2 fix (commit `4e5ee90`) changed what
`HeightAt` returns — it now reports the **drawn** surface rather than the naive read at the query
point, a difference of up to **1.30 studs** at p99 in a rough sea.

So a fish now floats at the surface the mesh actually draws, the same as ships, props and the swimmer.
That is the intent, and it is the only fishing-visible consequence of the ocean work. Nothing else in
the fishing path was edited by this branch: `FishingServer`, `FishingClient`, `FishPose` and
`FishingSounds` all still match the Studio copies byte-for-byte (45/45 parity after `a4ef9a0`).

The rod-UI tuning change (`856fb63`, D-08) was repo-only: it ported the values the user already had in
Studio into the repo, so the Studio behaviour is unchanged.

---

## 4. Latent item carried forward (D-14)

`FishingServer:55-60` creates its remotes at runtime:

```
local fishEvent = remotes:FindFirstChild("FishEvent") or Instance.new("RemoteEvent")
```

`remotes` is `tool.FishingRemotes`, created just above if absent, so it is self-healing and both
remotes were live in this session. The client's `WaitForChild` therefore resolves. Still a standing
order-dependency rather than a defect — recorded as P3, **not** changed, because changing the remote
topology is a fishing rewrite and fishing is accepted as working.

---

## 5. Verdict

| Item | Status |
|---|---|
| Grab is a `DragDetector` | **PASS** (structural: no movers exist in the fishing path at all) |
| Remotes live after equip | **PASS** (`FishEvent`, `Action`) |
| DragDetector present on a caught fish | **not observed** — needs a full cast cycle |
| Fish floats on the drawn surface | by construction (shared solver), not eyeballed |
| Repo/Studio parity for fishing files | **PASS** (0 diff) |
| Fishing behaviour regressions found | **none** |

Nothing in this pass justified a commit: fishing required no change, and inventing one would have been
exactly the "don't fix what was accepted" mistake. The only durable output is this record plus the
confirmation that the ocean fix reaches fish the same way it reaches hulls.
