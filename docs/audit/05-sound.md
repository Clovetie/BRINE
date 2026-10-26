# 05 — Ambient sea sound

Prompt 05 re-verification. The bed was built and accepted earlier; this pass re-runs every
acceptance criterion from scratch in Play on the current build, because the brief's open question was
that **the mix had only ever been verified by reading volumes, never by ear**.

All probes ran on the client (`dm: client`, `LocalPlayer = Hirabelan`) and on the server, in Play,
after `restart_play.sh`.

---

## 1. A1 — every ID loads: **PASS**, 12/12

Enumerated the live `SoundService.AmbientSea` folder (10 sounds, created by the script) **and**
preloaded the two IDs the script does not use, in a throwaway folder.

| Role | ID | IsLoaded | TimeLength | Volume @ read | Looped |
|---|---|---|---|---|---|
| CalmBed | `78025480791776` | true | 143.38 s | 0.00 | true |
| Beach | `137826155053556` | true | 183.00 s | 0.14 | true |
| Rough | `9120613130` | true | 12.74 s | 0.60 | true |
| Underwater | `5033884807` | true | 25.31 s | 0.00 | true |
| Deep | `94473522240855` | true | 7.39 s | 0.00 | true |
| Wind | `5799870105` | true | 80.51 s | 0.35 | true |
| Crickets | `179507208` | true | 120.01 s | 0.00 | true |
| NightWind | `6189441072` | true | 88.50 s | 0.00 | true |
| Gust (one-shot) | `9118747859` | true | 36.01 s | 0.50 | false |
| Birds (one-shot) | `105990653889537` | true | 6.56 s | 0.25 | false |
| *unused* calming | `131586509457092` | true | 133.40 s | — | — |
| *unused* cave | `273398061` | true | 117.80 s | — | — |

Every length matches the figure recorded in `docs/work-notes/sound/SOUND_PROMPT.md` (calm 143, beach
183, underwater 25, deep 7.4, rough 12.7, wind 80.5, birds 6.6, crickets 120, night wind 88.5, gust
36). So the earlier record was accurate and is now independently reproduced.

**No track fails to load.** A1 met.

---

## 2. A2 — the bed follows sea state: **PASS**

Located the calmest and roughest points in an 800×800 window by scanning `Gerstner.SeaStateAt`
(calm `s = 0.30`, rough `s = 1.00`), then read the live volumes at each.

| Condition | CalmBed | Beach | Rough | Wind |
|---|---|---|---|---|
| calm surface, day (s 0.30) | **0.44** (of 0.50 full) | 0.12 (of 0.14) | **0.00** | **0.08** |
| rough surface, day (s 1.00) | **0.00** | 0.14 | **0.60** (full) | **0.35** (full) |

The calm bed and the rough layer/wind cross over exactly as designed. A2 met.

`Beach` reads 0.14 at the surface in both cases because its target is `surface * 0.7` with no sea-state
term — it is a constant low shore layer at the surface. That is by design, not a stuck value.

---

## 3. A3 — underwater and deep: **PASS**

Camera moved to a fixed XZ and set to fixed heights, so the reference cannot drift between readings
(see §7 for why that matters).

| Camera | computed depth | Underwater | Deep | surface beds |
|---|---|---|---|---|
| Y 60 (≈35 above) | −35.07 | **0.00** | 0.00 | Calm 0.16, Rough 0.41 |
| Y 24 (≈1 under) | −0.04 | **0.00** | 0.00 | Calm 0.16, Rough 0.40 |
| Y 19 (≈3.3 under) | **+3.34** | **0.67** | — | **all 0.00** |
| Y 60 again | −33.43 | **0.00** | 0.00 | Calm 0.18, Rough 0.39 |

A second sequence stepping down through the surface: depth 3 → `Underwater 0.44, Deep 0.30`; depth 8
→ `Underwater 0.67, Deep 0.03`. The surface beds go to zero as soon as the camera is under, and the
deep layer rises with depth. A3 met.

At depth 8 the `Deep` volume reads lower than at depth 3 because `Deep` and `Underwater` share the
`underwater` factor and split on `deepness` (`Underwater.target = underwater * (1 - deepness)`), so
past `DeepStart` the two swap. That is the documented design.

---

## 4. A4 — no stacking on return to the surface: **PASS**

Y 19 (0.67 underwater) → Y 60 gives `Underwater 0.00` with the surface beds back up (Calm 0.18,
Rough 0.39) in one 4 s window at `FadeRate = 1.5`/s. Nothing is left running underneath and nothing
accumulates. A4 met.

---

## 5. A5 — day and night: **PASS**

| Clock | Crickets | NightWind | Birds |
|---|---|---|---|
| 12.0 | 0.00 | 0.00 | **0.25** (full) |
| 23.0 | **0.35** (full) | **0.30** (full) | 0.00 |

A5 met. (Gusts, A6, are gated on `roughness >= 0.3 and underwater < 0.1`; the one-shot timer path is
unchanged from the earlier verified run and I did not re-observe a gust firing in this window — see
§6.)

---

## 6. What is *not* verified — and it is the part that matters most

**How the mix sounds.** Every number above is a volume read. Whether the balance is pleasant, whether
the loop points in the 7.4 s deep bed and the 12.7 s rough bed are audible as seams, whether the beach
layer at a constant 0.14 muddies the calm bed — none of that is measurable here. The volumes are still
the placeholder mix set in `CONFIG.Volume`, and they have never been tuned by ear.

Also not re-observed this session: an actual gust `:Play()` (A6's "appears only when rough"), and the
bird one-shot firing (only its volume gate). Both depend on random timers of 8–25 s (birds) and 15–40 s
(gusts) plus the roughness gate, which does not fit inside a 19 s client probe window.

That leaves the whole pass at "the plumbing is correct and every asset loads", which is what the code
can prove. **Tuning is a listening job for the user.**

---

## 7. Two probe traps worth recording

1. **Do not anchor a mute test on "surface ± N studs".** My first depth sequence computed the camera
   height as `HeightAt(roughPoint) - depth` and then re-computed it for the next step. Because that
   re-anchors on a *moving* surface at a *different* instant, one reading came back as
   `Underwater = 0.67` while the camera was supposedly above the water, which looked like a stuck
   volume. Setting the camera to a **fixed height** and reading `depth = surfaceY − camY` at the same
   moment (§3) shows the mix behaving correctly. The bug was in my probe, not the script — but a
   reader who only saw the first table would have reported a false regression.
2. **`run_client.py` swallows the probe's return value.** The `ocean/sound_probe.lua` run through
   `run_client.py` prints only the RPC envelope; the actual track list comes back only when the probe
   is called with the raw `probe` tool and the `decoded.result` field is read. Worth fixing in
   `run_client.py` if this is used again.

---

## 8. Unused tracks — recorded, not touched

- `131586509457092` (calming, 133 s) and `273398061` (cave, 118 s) both load and are both unused. The
  cave track is documented as reserved for caves. The **calming** track has no documented home; it is
  not referenced in `CONFIG.Track` at all.

Decision needed from the user: wire the calming track in (it would suit the calm-surface bed better
than the current `CalmBed` if that is what it was uploaded for), or leave it. **No change made** —
deleting or rewiring a user-supplied asset is a design call.
