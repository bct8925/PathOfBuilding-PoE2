# CLAUDE.md

## Project goal

Add an **MCP server** to Path of Building 2 (PoB2), an offline build planner for
Path of Exile 2. The MCP lets an AI assistant inspect and modify PoB2 builds —
computing stats (DPS, EHP, resistances, …) and editing tree/items/skills/config.

Work happens on the `bri64-mcp` branch; upstream is the community PoB2 repo.

## Requirements

Full v1 requirements (FR/NFR, tool surface, open questions, phasing) live in
**`mcp-server/docs/REQUIREMENTS.md`** — read it before designing features.
Highlights:

- **Live GUI is the primary backend.** MCP tool calls **mutate a running PoB2's
  in-memory state** (tree, items, skills, config) and read results back live.
  Headless is the secondary backend, used for optimization/search (apply the
  winner to the live build).
- Use cases: **analyze/explain, suggest, optimize/search, author** builds.
- MCP server is **plain Lua** (in `mcp-server/`, on the `mcp-lua` library), launched by local Claude Code over stdio as `luajit mcp_server.lua`.
- Live-GUI link is an **in-app socket bridge** built into PoB2's source, gated by
  an Options toggle ("Enable MCP bridge"), off by default, pumped from `OnFrame`.
  It opens a local TCP socket (PoB2 bundles `socket.dll` + `runtime/lua/socket.lua`).
- Mutations **apply immediately**; revert via **PoB's native undo stack**.
- **Ships native-Windows-only, as a natural built-in PoB extension** — no WSL, no
  Node install, no toolchain expected of users. The server is plain Lua shipped in
  PoB's folder (`mcp-server/`), run by the bundled Windows `luajit.exe` (the same
  interpreter serves the headless backend). **WSL is dev-only and must not leak into
  the product** (resolve paths/runtime relative to the Windows distribution).
- Client-agnostic: stdio server + a documented config snippet for the user's MCP
  client.
- v1 operates on the **current build** only (+ new/save/save-as); **no external
  imports** (PoB codes, account import, trade) and no open-by-name.
- GUI must be **already running**; the MCP does not auto-launch it.

## Architecture

```
  AI client ── MCP ──> luajit mcp-server/mcp_server.lua ──┬─ spawn luajit run_headless.lua   (headless calc)
                       (mcp-lua: MCP over stdio)          └─ TCP socket ─> Lua bridge in running PoB2 GUI (live)
```

**The MCP server is plain Lua and lives in THIS repo at `mcp-server/`** — it ships as part of
PoB2, exactly like the in-app bridge. There is no Node/TypeScript and no build step; the bundled
`runtime/luajit.exe` runs both the server and the headless calc. Key files:
`mcp-server/mcp_server.lua` (entry: bootstrap + register tools + serve stdio),
`mcp-server/lua/tools/` (the tool registry — source of truth, split by domain),
`mcp-server/lua/bridge.lua` (TCP client to the GUI) ↔ `src/Modules/MCPBridge.lua` (the in-app
socket server, loaded lazily by `main:PumpMCPBridge` when the "Enable MCP bridge" Option is on),
`mcp-server/lua/engine.lua` + `mcp-server/lua/run_headless.lua` (headless backend),
`mcp-server/lua/optimize.lua` (search scoring), `mcp-server/lua/config.lua` (path/runtime
resolution). MCP protocol is the **`mcp-lua`** library, vendored at `mcp-server/vendor/mcp-lua/`
(developed at `~/Dev/mcp-lua`; re-vendor with `mcp-server/scripts/sync-mcp-lua.sh`).
Tests: `mcp-server/test/test_server.lua` (wiring), `mcp-server/test/integration_headless.lua`
(MCP-over-stdio e2e), `mcp-server/test/test_bridge.lua` (200+ MCPBridge checks) — run all via
`mcp-server/run_tests.sh`. Packaging: `scripts/build-dist.sh` (stages `mcp-server/` + `runtime/`
+ `src/`; no exe) + `scripts/dev-update-local.sh`.

The **`pob2-mcp/` submodule** (repo: github.com/bct8925/pob2-mcp — a marketplace whose one plugin
`plugins/pob2-mcp/`) now holds **only the plugin definition + skills**: `.claude-plugin/plugin.json`,
`.mcp.json` (launches `luajit ${POB_ROOT}/mcp-server/mcp_server.lua`), and `skills/`. Run
`git submodule update --init` after cloning. Three **skills** under `plugins/pob2-mcp/skills/`:
`poe2-build` (the build-authoring workflow that drives the `gui_*` tools), `poe2-mechanics` (PoE2
concepts + real PoB stat/config vocabulary), and `poe2-sync` (`/poe2-sync` — refresh that
knowledge from the latest patch notes). Install the marketplace to use them as a plugin.

In the **WSL dev env** the server runs under Linux `luajit` (spawning the Linux `luajit` headless
engine) and reaches the GUI over TCP localhost. The product ships **native-Windows-only**: the
`mcp-server/` Lua tree + bundled `runtime/luajit.exe`, no Node and no toolchain. The remaining
step is the native-Windows live-GUI acceptance run.

- **PoB2 core**: Lua 5.1 / LuaJIT. GUI is a native x64 Windows exe
  (`runtime/Path of Building-PoE2.exe`) using `SimpleGraphic.dll`.
- **Headless entry**: `src/HeadlessWrapper.lua` stubs the graphics/IO layer so the
  full engine runs under plain LuaJIT. Helpers: `newBuild()`,
  `loadBuildFromXML(xml, name)`, `loadBuildFromJSON(...)`. The loaded build is the
  global `build`.
- **Reading stats**: after `runCallback("OnFrame")`, read `build.calcsTab.mainOutput.*`
  (e.g. `.Life`, `.CritMultiplier`); raw modifiers via `build.calcsTab.mainEnv.player.modDB`.
- **Bundled pure-Lua libs** (no compilation): `runtime/lua/` — `xml`, `sha1`,
  `socket`, `dkjson`, `base64`. The only compiled module PoB2 needs is `luautf8`.
- **Generated data**: files under `src/Data` with header
  `-- This file is automatically generated` come from `src/Export` scripts; edit the
  exporter, not the data.

### Environment notes (Debian 13 / Windows WSL2)

- The Windows GUI runs **directly via WSL interop** — no Wine.
- The server is plain Lua — no Node. Linux dev needs `luajit` + `luasocket` (the
  bridge client's TCP core); `scripts/install-deps.sh` provisions both.

## Build / test

Install the Lua toolchain (apt + luarocks; needs sudo):

```bash
scripts/install-deps.sh      # luajit, lua5.1, liblua5.1-dev, luarocks, build-essential; luarocks: luautf8 + luasocket + busted
```

Run the headless engine:

```bash
cd src && LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;" CI=true luajit HeadlessWrapper.lua
```

Run the test suite (busted) — **from the repo root**, where `.busted` lives:

```bash
busted --lua=luajit
```

(CI also runs the suite in the `ghcr.io/pathofbuildingcommunity/pathofbuilding-tests` Docker image via `docker-compose up`.)

Run / test the MCP server (plain Lua — no build step). The server is `mcp-server/mcp_server.lua`;
the MCP client launches it as `luajit mcp-server/mcp_server.lua` with `POB_ROOT` in the env:

```bash
mcp-server/run_tests.sh    # wiring (test_server) + MCP-over-stdio e2e (integration_headless) + MCPBridge regression (test_bridge)
LUA_BIN=lua5.1 mcp-server/run_tests.sh    # also verify under Lua 5.1
```

The MCPBridge regression suite also runs standalone from `src/`:
`LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;" CI=true luajit ../mcp-server/test/test_bridge.lua`

Launch the Windows GUI (WSL interop):

```bash
"runtime/Path{space}of{space}Building-PoE2.exe"
```

`CI=true` skips loading the large generated `src/Data/ModCache.lua` at boot. If you
change mod-parsing logic, reload PoB with `Ctrl`+`F5` in the GUI to regenerate
`src/Data/ModCache.lua`, and commit it if it changes.
