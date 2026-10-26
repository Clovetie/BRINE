# Agent prompts: BRINE audit, polish, and fix

Start here. Read this file first, then the prompts in order (01 to 09). Each prompt is self-contained, but the ground rules below apply to all of them.

## Branch and git rules
- Work on the branch `arena/ocean-sound-and-audit` (or a child branch of it). **Never push to `main`.** The user opens or merges the PR.
- The branch was created from `main` at `0d18c1b` (PR #8). It includes the ocean, sound, ship, floating, fishing, and swim work from the session that wrote these prompts.
- Commit in small, named units. Message format: `Area: what changed`, with the reason and any measured numbers in the body.
- Do **not** commit `tools/audit.sh` (mode change only). Do **not** commit anything under `.mcp/` or `probes/mcp_init.py`. Those hold the Studio bridge token.
- No pushes to git until the user says so. Pushes to Studio are allowed for verification, and they must be read back and compared with the repo afterwards.

## Token handling
- A GitHub token was pasted in chat during the session that wrote these prompts. **Treat it as exposed.** Ask the user to revoke and rotate it before relying on it again.
- Never write a token into a file, a commit, a log, or a prompt. Pass it in a single command, for example `git push "https://x-access-token:${TOKEN}@github.com/Clovetie/BRINE.git" HEAD:refs/heads/<branch>`.
- The clone has no `origin` remote configured. Use the explicit URL above, or add the remote without a token.

## Ground rules (game)
- `ServerBoat` is the physics reference. Do not change it.
- Keep working behaviour intact: ships, swimming, fishing, floating objects, hand-holding, islands.
- No ocean texture work.
- `Workspace.Part` is the platform slab for placing parts. Do not delete it.
- Anti-sinking: do not add overhang-sink code for unsupported platforms. The user will make platforms solid.
- Floating objects must not be despawned, culled, or lifetime-expired while in a player's sight.
- Hirabelan is a real player, not a rig.
- Keep live Studio tuning values unless the prompt says otherwise. If Studio and the repo disagree, record the difference before changing either.

## Checks to run before every commit
```
cd /home/user/BRINE/tools && npm ci            # needed if tools/node_modules is missing
cd /home/user/BRINE && chmod +x .tools/bin/*
node tools/smoke-test.js                       # baseline: 83 passed, 0 failed
node tools/check-syntax.js                     # baseline: 23 files parse
node tools/validate-project.js                 # baseline: tree is consistent
.tools/bin/luau-compile <file>                 # exit 0 for every changed Luau file
```
`selene` cannot lint Luau here. Use `luau-compile` and `luau-analyze`. Roblox globals show up as "unknown global" warnings there, which is expected.

## Studio workflow
- Bridge helpers are in `tools/studio-probes/`. The bridge client and token are not in the repo. Recreate them locally before using Studio.
- Push a file: `ocean/push_file.py` or `bridge/push_src.py`. Read back with `bridge/get_src.py` and diff against the repo. Do not trust a push until the read-back matches.
- Client jobs time out after about 20 seconds (`client RPC timed out waiting for client DataModel`). Keep each client probe under about 15 seconds, and split longer checks into several probes.
- A client probe needs Play with a client peer. Start Play with `ocean/restart_play.sh`. A `no_client_peer` result means the peer dropped: wait a few seconds and retry.
- End Play when finished: probe `dm=server` with `StudioTestService:EndTest("done")`. `start_stop_play` with `stop` from edit does not work here.
- Studio changes made by a script are not in the repo until committed. Keep the two in step.

## Known tool quirks
- The Studio bridge tool `execute` does not exist. Use `probe`.
- `search_assets` takes `assetType` values `any`, `image`, `sky`, `model`, `audio` (lowercase).
- `capture_viewport` is a software rasterizer. It does not render Roblox water shading, so it cannot judge wave looks. Visual judgement needs the user, or a Studio view they can see.
- `Lighting.Technology` cannot be read in edit mode. Do not read it.
- A `dm:"client"` probe sometimes runs as a server job. Check `LocalPlayer` in the output to confirm where it ran.
- `multi_edit` once returned `luauCheck.ok=false` with no compile errors on two config modules. Unexplained. Re-check any multi-edit result with `luau-compile`.

## Prompt order
1. `01-audit-everything.md`: inventory, parity, dead code, and the list of defects.
2. `02-waves-collision-and-spasms.md`: P0. Wave collisions and visual spasms in rough and calm transitions.
3. `03-ocean-performance.md`
4. `04-ocean-seam-and-immersion.md`
5. `05-sound-ambient-sea.md`
6. `06-fishing.md`
7. `07-ships-and-physics.md`
8. `08-floating-and-islands.md`
9. `09-polish-and-debug-sweep.md`: the final pass, after the others.

## Report format (every prompt)
- What changed (files and commits), what was verified (with the numbers), what was not verified (with the reason), and what needs the user's eyes or ears.
- Anything that contradicts these prompts. Say so; do not silently follow the prompt.

## Where the history is
- `docs/work-notes/ocean/NOTES.md`, `PROMPT.md`, `docs/work-notes/sound/SOUND_PROMPT.md`, `docs/work-notes/fishing/NOTES.md`, `docs/work-notes/miso/NOTES.md`.
- `ROADMAP.md` (phase status), `BOAT_HANDLER.md`, `SWIMMING.md`.
