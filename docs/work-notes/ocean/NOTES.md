# Ocean notes

## Measured (dm=client, `OCEANPERF` / `OCEANPERF2`, REPORT_EVERY 300, per worker per frame)
| Variant | Writes | Serial ms | Parallel ms |
|---|---|---|---|
| base (FAR/UV 1/1, MeshDetailDistance 200) | 239, 237 | 0.224, 0.221 | 0.493, 0.503 |
| new (FAR/UV 3/3, MeshDetailDistance 120) | 110, 128 | 0.105, 0.136 | 0.354, 0.426 |

Two sessions each. Serial write cost is down about 40–50%; parallel compute is down about 15–30%.
Frame-rate A/B on this host is not usable (see PROMPT). Decide on these counts, not on fps.

## Baseline (client, 6 s sample)
Workers on: mean 23.1 ms, p95 63.9 ms. Workers destroyed: mean 14.0 ms, p95 45.4 ms.

## Accepted for now
- FAR_WRITE_EVERY / UV_WRITE_EVERY = 3 (far vertices and UV scroll at 20 Hz). Step per write is at most about 0.12 studs, far away. Visual check still owed. FAR_WRITE_EVERY = 2 is the middle option if it looks steppy.
- MeshDetailDistance 120 (was 200). Lerp error for LOW vertices is analytic only: about 0.08 studs for the largest wave, 0.03 for λ=25. Not yet measured in Play.

## Immersion
- SwimClient underwater block: classic fog closes in over MURK_DEPTH = 3 studs to MURK_FOG_END = 120, colour to a teal murk, AmbientReverb UnderWater past 50%. Probe-verified with a scripted camera (camdepth 0.5 → 8: FogEnd 14490 → 120). Restores on surface.
- Not verified: how the sea plane looks from below (single-sided?), and the surface seen from underwater.
- Ambient sea sound: none exists. The two `Splash` loops on WoodenShip and Boathouse have volume 0. The asset search has no water/sea audio. Needs a user-supplied asset ID.

## Open
- Outer-edge seam at FrustumRenderDistance 900 (wave mesh ends, flat secondary planes beyond). Not investigated.
- Remaining hypotheses (serial vs parallel cost, colour threshold, per-vertex SeaStateAt, far-chunk update rate).

## Round 2
- Outer edge: the main plane is centred at (0, 25, 288), size 1872, so its edge is about 936 studs from the camera. The flat outer tiles sit at y 25. Ring samples (dm=client, 4 waves, 4 times): max |dy| about 4 studs at 600–880 studs, 2.7–3.4 at 900–960. Fix: Lighting fog 500 to 880 (client, in SwimClient). Visual check still owed, since capture_viewport cannot render water.
- SeaStateAt per-vertex cost: not resolved. Field on: parallel 0.429 ms. Field skipped (return 1): 0.441 and 0.444 ms. Within noise, so it is not the cost driver.
- Serial (main thread) is about 0.14 ms per worker, about 0.84 ms per frame for 6 workers. Parallel is about 0.43 ms per worker. Neither explains the 9 ms mean difference from the baseline (workers on vs destroyed). The likely driver is the EditableMesh write upload and/or rendering, so the next test is write count vs frame time, not more compute.
- Studio restored to repo versions (Settings with REPORT_EVERY 0, Gerstner init, Setup, SwimClient); read-back matched. Play ended.
