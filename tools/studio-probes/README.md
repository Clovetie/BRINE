# Studio probes (work tools)

These scripts were used to push code to Roblox Studio, read it back, run Play, and measure the ocean and sound from a client. They talk to the Studio MCP bridge through `call.py`.

- The bridge client (`.mcp/call.py`) and its session setup (`probes/mcp_init.py`) hold a bridge token. They are **not** in the repo. Recreate them locally from the bridge settings. Never commit them.
- `bridge/push_src.py` pushes a repo file into Studio: `<parent> <name> <className> <repo_path>`, where the repo path is relative to `/home/user`.
- `bridge/get_src.py` reads a Studio script back to a file, for comparison against the repo.
- `ocean/run_client.py <file.lua> [timeout]` runs a Lua file in the client data model. Client jobs time out after about 20 seconds, so keep each probe short.
- `ocean/restart_play.sh` ends Play and starts it again with a client peer.
- `ocean/push_file.py` pushes a local file via `write_script`.
- `ocean/perf2.sh` and `ocean/perf_read.sh` read the `OCEANPERF` / `OCEANPERF2` lines from the console.
- `ocean/variants/` holds the Settings variants used for the write-budget A/B (base and new).
