# BRINE Lua tooling

Local, repeatable analysis and quality tooling for the BRINE Luau scripts.
Everything in this folder is the reusable setup for future work. Generated
output goes to `tools/reports/` (git-ignored); build caches live under
`.tools/` and `tools/node_modules/` (both git-ignored).

## Quick start

```bash
bash tools/setup-tools.sh     # optional: installs selene/stylua/luau into .tools/
npm --prefix tools install    # installs luaparse for check-syntax.js

# One-shot audit (no external deps needed beyond node + luaparse):
bash tools/audit.sh
bash tools/audit.sh --json    # also writes JSON reports into tools/reports/
```

`tools/audit.sh` runs **all** the tools below and prints a combined report.

---

## Analysis tools (these are the "future-iteration toolkit")

All are **dependency-light Node** scripts (only `tools/run-node` needs
`luaparse`); they are heuristic, not compilers, and each prints its own caveat.

### `call-graph.js` — module dependency + orphan/public-API surface

Builds the `require()` dependency graph and, for every exported function, tells
you which module(s) call it. It then reports **orphaned exports** (defined but
never referenced by another module) — this is the machine-checked version of the
"dead/library-only code" finding in [`../AUDIT.md`](../AUDIT.md).

```bash
node tools/call-graph.js                     # human-readable table
node tools/call-graph.js --json reports/call-graph.json
```

Recognises `Helper.GetX`, `Module:Method`, `local Alias = require(...)`,
`local X = Mod.new(); X:Method()`, and Luau generics (`function Octree:CreateNode<T>()`).

### `metrics.js` — code-health / complexity trend

Per-file LOC, comment ratio, exported count, `require` count, heuristic
**cyclomatic complexity**, and a count of "heavy" constructs (raycasts,
`task.`, tween/mesh creation, physics movers, table churn). Useful to spot files
growing too large or too branchy across iterations.

```bash
node tools/metrics.js [--top 8] [--json reports/metrics.json]
```

### `validate-project.js` — Rojo project + layout gate

Checks `default.project.json` against the `src/` tree and enforces the Rojo
file-layout rules this repo depends on:

- a `$path` that points at a missing file/folder;
- the forbidden `Foo.luau` + `Foo/` sibling collision;
- a module folder missing its `init.luau`;
- known `.model.json` contract names (e.g. it flags `EditZone` staying a
  `BindableEvent` when the code needs a `RemoteEvent`).

```bash
node tools/validate-project.js [--json reports/project-validation.json]
```

### `find-dead-config.js` — unused settings knobs

Finds config keys that are declared but never read anywhere else in the tree.
It supports both config styles (`return { Key = ... }` and
`local C = {}; C.Key = ...; return C`). Verified on this repo: it flags
`WORKER_COUNT`, `FrustumRenderDistance`, `MaxChunkRenderDistance`, and
`FRUSTUM_CULLING_FIX` in `Settings` as unread.

```bash
node tools/find-dead-config.js [--file path] [--json reports/dead-config.json]
```

### `hot-loop-scan.js` — per-frame / loop hot-path risk

Flags expensive calls (`workspace:Raycast`, `RaycastLocal`, `GetAllNodes`,
`:Clone`, `GetPartBoundsInRadius`, `GetServerTimeNow`, `table.sort`, etc.) and
whether each sits inside a `for`/`while`/`repeat` body or a `RunService.*`
callback file. It uses a lightweight block-stack lexer, so the "LOOP"/"FRAME"
markers are a strong pointer, not proof.

```bash
node tools/hot-loop-scan.js [--top 20] [--json reports/hot-loop-scan.json]
```

### `check-syntax.js` — Luau-subset syntax gate

The project's original syntax checker. Uses `luaparse` to catch missing `end`s
and structural mistakes after stripping Luau-only syntax.

```bash
node tools/check-syntax.js
```

### `evaluate-models.js` — LLM preflight gate

Provider-neutral fail-closed admission gate for candidate text models. The
production prompt is never accepted here. See [`EVALUATION.md`](EVALUATION.md).

```bash
node tools/evaluate-models.js --models tools/models.example.json --suite tools/evaluation-suite.example.json
```

> The example adapter (`my_model_adapter.py`) doesn't exist, so the example
> reports `REJECT 0.0%` — that is the correct, by-design fail-closed behavior.

---

## Shared library

`lib/luau.js` is the shared, zero-dependency analysis engine used by the tools
above. It provides:

- `stripCommentsAndStrings` — masks code so heuristics act on real code only
  (correctly handles `--[[ ]]`, `--[=[ ]=]`, `[[ ]]`, quotes, backticks).
- `collectLuauFiles`, `moduleInstanceName` (Rojo init/layout aware).
- `extractDefinitions`, `extractRequires`, `extractReferences`,
  `extractInstanceRefs`, `buildInstanceVarMap`, `analyseFile`.

---

## External ecosystem tools (set via `setup-tools.sh`)

The repo also supports the standard Roblox/Luau toolchain. `setup-tools.sh`
installs into `.tools/` (git-ignored): `stylua` (formatter), `selene` (linter),
and `luau`/`luau-analyze` (compiler/analyzer). The linter/analyzer configs live
here:

```bash
.tools/bin/stylua --config-path tools/stylua.toml --check src
.tools/bin/selene --config tools/selene.toml src
.tools/bin/luau-analyze src
```

The toolchain manager **Rokit** is the recommended way to pin versions in CI:

```bash
curl -sSf https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.sh | sh
rokit add rojo-rbx/rojo
rokit add Kampfkarren/selene
rokit add JohnnyMorganz/StyLua
rokit install
```

**Recommendations from ecosystem research** (see the `tools/` docs for the full
rationale): `luau-lsp` for in-editor type checking, `TestEZ` for Luau unit
tests, `Wally` for packages, and `Lune` for Luau CI scripts.

---

## CI

`.github/workflows/ci.yml` runs the deterministic Node analysis (`audit.sh`)
and optionally the ecosystem linters when `selene`/`stylua`/`luau-analyze` are
available. The Node tools are the stable baseline that works without network.

---

## Setup

```bash
bash tools/setup-tools.sh
```

Installs into `.tools/`:

- `stylua` — Luau formatter (config: `tools/stylua.toml`)
- `selene` — Lua linter (config: `tools/selene.toml`)
- `luau` / `luau-analyze` — Luau compiler + analyzer
- `luaparse` (npm, under `tools/node_modules`) — lightweight syntax parse
