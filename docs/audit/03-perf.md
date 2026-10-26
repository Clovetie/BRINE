# 03 — Ocean performance

Prompt 03 pass, first measurements. All numbers come from the worker's own instrument
(`Settings.PERF.REPORT_EVERY`, `OCEANPERF` / `OCEANPERF2` warnings) read with
`tools/studio-probes/ocean/perf2.sh`. **The repo keeps `REPORT_EVERY = 0`**; 300 was set only in the
Studio copies used for measurement, and the repo Settings were pushed back and read back
(188/188 lines, 0 diff) afterwards.

Method follows the prompt: one variant file per change, push, restart Play, wait 30 s, read; **two
sessions per variant**; a change counts only if both sessions agree on direction.

Raw sample counts: `n = 48–54` reports per worker per session, i.e. 14 400–16 200 frames of data.

---

## 1. Write-budget A/B (prompt 02 S1 × prompt 03 hypothesis 1)

"Write upload is the main cost" — this is the test, because it moves the write count and nothing else.

| Variant | `FAR_WRITE_EVERY` | `UV_WRITE_EVERY` | writes/worker/frame | serial ms | parallel ms |
|---|---|---|---|---|---|
| **A** — old default | 3 | 3 | 127.0 | 0.144 | 0.445 |
| **A** — session 2 | 3 | 3 | 136.5 | 0.153 | 0.484 |
| **A** mean | | | **131.8** | **0.1485** | 0.465 |
| **C** — new default | 1 | 3 | 225.0 | 0.228 | 0.510 |
| **C** — session 2 | 1 | 3 | 225.5 | 0.223 | 0.511 |
| **C** mean | | | **225.3** | **0.2255** | 0.511 |
| **B** — every-frame (one session) | 1 | 1 | 237.5 | 0.297 | 0.583 |

What this says:

- **Serial time tracks the write count almost exactly.** A → C is +93.5 writes and +0.077 ms; that is
  **0.82 µs per write**. So hypothesis 1 is right in mechanism: the serial section *is* the write
  upload, and it is essentially linear in writes.
- **`UV_WRITE_EVERY` is a better lever than the write count suggests.** B → C is only −12.5 writes
  but −0.071 ms, i.e. about **5.7 µs per UV write** against 0.82 µs for a position write. If that
  holds (it is one session each, so treat it as a lead, not a result), UV writes are ~7× more
  expensive per call than position writes, and the UV scroll should be the first thing any further
  budget work targets — it is a pure texture scroll.
- **Parallel time barely moves** (0.465 → 0.511 ms, +10%), which is expected: the parallel section
  computes every visible vertex every frame regardless of the write budget. **Hypothesis 1's
  corollary is confirmed: the budget never saved compute, only upload.**

### Where the repo now sits

`FAR_WRITE_EVERY = 1`, `UV_WRITE_EVERY = 3` — variant C. That is **+0.46 ms/frame** across six
workers on the main thread against the old default, paid deliberately to remove the 20 Hz far-field
stepping documented in `02-waves-findings.md` §4.

### Against the documented baseline

`docs/work-notes/ocean/NOTES.md` records two rows:

| Variant | Writes | Serial ms | Parallel ms |
|---|---|---|---|
| Original (far and UV every frame, mesh detail 200) | 237–239 | 0.22 | 0.49–0.50 |
| Current (far and UV every 3 frames, mesh detail 120) | 110–128 | 0.11–0.14 | 0.35–0.43 |

My session-1 numbers reproduce the "current" row closely (127 writes, 0.144 ms) and my **B** row
reproduces the "original" write count (237.5 vs 237–239) — but at 0.297 ms serial, not 0.22. The
write counts agree; the serial time is 35% higher than documented. Either this host is slower per
write than the machine the notes were taken on, or something else in the serial section grew. I am
**not** claiming a regression: the notes do not record their `n`, session count, or host, so the
comparison is not controlled. Flagged so the next person does not read 0.297 as a regression.

---

## 2. Cost of the correctness fix from prompt 02

`WaveFloat.HeightAt` now solves the horizontal inverse (3 fixed-point steps). This does **not** touch
the ocean mesh — the mesh writes go through `Gerstner.ComputeTransform` directly in
`ParallelWorker`, never through `WaveFloat`. It affects ships, floating props, swimming and fishing.

Headless cost, same point, no zones (`tools/measure-height-error.sh`):

| `INVERSE_STEPS` | HeightAt/s | µs per call | vs old |
|---|---|---|---|
| 0 (old) | 532 942 | 1.876 | 1.00× |
| 2 | 178 893 | 5.590 | 2.98× |
| **3 (default)** | **133 308** | **7.501** | **4.00×** |

The multiplier is exactly the evaluation count (K steps + 1 read, first step re-using the sample
already taken), so this is arithmetic, not a surprise.

Exposure: `FloatingObjectConfig.Scheduling.UpdateInterval = 0.12` for the far band,
`NearUpdateInterval = 0`, `MaxRenderedObjects = 500`, and `WaveFloat.Solve` makes 4 `HeightAt` calls
per object. Worst case — every one of 500 props updating every frame — is 2 000 calls/frame; at the
measured 3.0–4.0× that is the difference between roughly 3.8 ms and 15 ms per frame on one core.

**This is the one number I want to re-measure in the real engine before anyone tunes it.** The
headless µs are a plain Luau VM, not Roblox, and the props are spread over the far cadence in
practice. If it turns out material, the knob is already there: `WaveFloat.INVERSE_STEPS = 2` still
passes A1 (p99 0.0343 studs against a 0.1 budget) at 2.98× instead of 4.00×, for a 1.9% frame-time
difference at the 500-prop extreme.

---

## 3. Hypotheses from the prompt, scored

| # | Hypothesis | Status |
|---|---|---|
| 1 | Write upload is the main cost | **Supported.** Serial ms is ~linear in writes at 0.82 µs/write; the budget moved serial time 0.1485 → 0.2255 ms and moved parallel time by only +10%, proving it never saved compute. |
| 4 | Far-chunk update rate | Partly answered by §1 — the far rate *is* the write count, and writing every frame is now the default for correctness. A cheaper path would have to preserve landing on the same frame as neighbours. |
| 5 | Serial vs parallel split | **Measured.** Serial 0.1485 ms vs parallel 0.465 ms per worker at the old default. The serial section is the one that scales with writes and it runs on the main thread, so it is the one on the critical path. |
| 2 | Rendering cost (chunks, draw calls, triangles) | **Not measured.** No draw-call or triangle counts taken yet. |
| 3 | Colour threshold (`LowRenderDistance` 200) | **Not measured.** |
| — | UV write cost | **New lead** from §1: ~7× the cost per call of a position write. Worth attacking before draw calls. |

---

## 4. Not done

- No frame-rate A/B. The notes warn that frame-rate A/B on this host has been unreliable (off-state
  medians 23–63 fps), and I have no same-window control, so I make no fps claim at all.
- No `n` for the documented baseline rows, so §1's cross-check is indicative only.
- Not verified: whether variant C *looks* better at distance. That is the user's eye (prompt 02 §4).
