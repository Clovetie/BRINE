# 03: Ocean performance

## Goal
Lower the ocean's cost without making it look worse. Measure every change. Keep the visual results from `02` and `04` intact.

## Current state (from `docs/work-notes/ocean/NOTES.md`)
- Per worker, per frame (dm=client, `OCEANPERF` / `OCEANPERF2`, REPORT_EVERY 300):

| Variant | Writes | Serial ms | Parallel ms |
|---|---|---|---|
| Original (far and UV every frame, mesh detail 200) | 237 to 239 | 0.22 | 0.49 to 0.50 |
| Current (far and UV every 3 frames, mesh detail 120) | 110 to 128 | 0.11 to 0.14 | 0.35 to 0.43 |

- Baseline on this host (6 s sample): workers on, mean 23.1 ms and p95 63.9 ms. Workers destroyed, mean 14.0 ms and p95 45.4 ms. The difference is about 9 ms mean, which the per-worker numbers do not explain.
- The per-vertex sea-state field costs nothing measurable (parallel 0.429 ms with it on, 0.441 and 0.444 ms with it skipped).
- Frame-rate A/B on this host has been unreliable (off-state medians from 23 to 63 fps across runs). Do not decide on frame rate from one run.

## Open hypotheses
1. **Write upload is the main cost.** About 780 EditableMesh writes per frame across six workers. Test: count writes against frame time, using a variant where the write count is halved (writes every other frame for all vertices) versus full. Write count, not compute, may be the driver.
2. **Rendering cost.** About 193 chunks and about 3300 vertices. Test: merge or cull chunks at distance, and reduce draw calls. Measure the rendered triangle count before and after.
3. **Colour threshold.** `LowRenderDistance` 200 controls the colour path. Test: move it and measure. Keep the visual colour boundary where the user is happy with it.
4. **Far-chunk update rate.** Chunks beyond `MaxChunkRenderDistance` 800 do no work. Test: whether a lower far rate saves time without visible stepping (coordinate with `02`).
5. **Serial vs parallel split.** Serial is about 0.14 ms per worker (about 0.84 ms per frame in total on the main thread). Parallel is about 0.43 ms per worker. Work out which of these is on the critical path.

## Method
- Use one variant file per change (`ocean/variants/`-style). Push, restart Play with `ocean/restart_play.sh`, wait about 25 s, and read with `ocean/perf2.sh`. Do each variant in two sessions.
- Record the mean of the per-worker numbers and the session count. A change is real only if both sessions agree on direction and the change is larger than the spread between sessions.
- Keep `PERF.REPORT_EVERY` at 0 in the repo. Use 300 only in Studio, during measurement.

## Acceptance criteria
- A1: A measured reduction in the main-thread cost or the write count, with the method and the numbers recorded.
- A2: No visual regression in the checks of `02` (vertex motion and height error).
- A3: The baseline table in `docs/work-notes/ocean/NOTES.md` is updated with the new numbers.
- A4: Repo and Studio match at the end (read back).

## Do not
- Do not push any frame-rate claim without a same-window control.
- Do not remove the near-field detail to save time without the user's approval.

## Deliverables
- Commits for each accepted change, with the measurement in the body.
- An updated `docs/work-notes/ocean/NOTES.md` (or `docs/audit/03-perf.md`).
