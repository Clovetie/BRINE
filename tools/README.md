# BRINE Lua tooling

Small, local tools for checking and formatting the Luau scripts in this repo.
The `.tools/` cache is git-ignored; the scripts/configs here are the reusable,
repeatable setup for future work.

## Setup

```bash
bash tools/setup-tools.sh
```

This installs into `.tools/`:

- `stylua` — Luau formatter (config: `tools/stylua.toml`)
- `selene` — Lua linter (config: `tools/selene.toml`)
- `luau` / `luau-analyze` — Luau compiler + analyzer
- `luaparse` (npm, under `tools/node_modules`) — lightweight syntax parse

## Checks

```bash
node tools/check-syntax.js                      # quick structural syntax check
.tools/bin/stylua --config-path tools/stylua.toml --check src
.tools/bin/selene --config tools/selene.toml src
.tools/bin/luau-analyze src
```

`tools/check-syntax.js` uses `luaparse` to find missing `end`s and other
structural mistakes. It strips Luau `:: Type` casts before parsing because
`luaparse` only understands standard Lua; run `luau-analyze` for full Luau
static analysis.
