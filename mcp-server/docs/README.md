# pob2-mcp

MCP server for Path of Building 2. Lets an AI assistant **analyze, edit, and optimize**
PoB2 builds — primarily by driving a **live, running PoB2 GUI** so changes appear on
screen immediately, with a headless calc engine behind optimization/search.

See `REQUIREMENTS.md` for the full v1 spec and delivery status.

## Backends

| Backend | How | State |
|---|---|---|
| **Live GUI** (primary) | TCP socket to an in-app Lua bridge in the running GUI | ✅ working |
| **Headless** | Spawns `luajit` on `HeadlessWrapper.lua` per call | ✅ working |

Every `gui_*` mutation applies to the live build, recalcs, and returns refreshed stats;
reverts go through PoB's native undo. Optimization evaluates AI-proposed candidates
headlessly off a snapshot, then applies the winner live.

**Dev runs under Linux Node (in WSL)** so it can spawn the Linux `luajit`; it reaches the
Windows GUI over TCP localhost. The **shipped** product is native-Windows-only — a single
self-contained `.exe` with a bundled Windows `luajit.exe` (see Packaging).

## Layout

```
mcp/
  src/
    index.ts             MCP server entry (stdio); registers all tools (source of truth)
    config.ts            repo/luajit/runner path + bridge host/port resolution (env-overridable)
    engine/headless.ts   spawn luajit, feed JSON request, parse @@POB_RESULT@@ JSON
    engine/optimize.ts   score candidate change-sets to an objective (gui_optimize)
    bridge/socket.ts     TCP client for the live-GUI bridge (newline-delimited JSON)
    smoke.ts             end-to-end HEADLESS check (npm run smoke)
    smoke_bridge.ts      end-to-end LIVE-GUI check over the socket (npm run smoke:bridge)
  lua/
    run_headless.lua     boots HeadlessWrapper, applies a request, emits JSON
    test_bridge.lua      headless exercise of the bridge dispatch logic (no socket; 200+ checks)
```

The in-app socket server is built into PoB at `../src/Modules/MCPBridge.lua`; it is loaded
lazily by `main:PumpMCPBridge` (`Modules/Main.lua`) when the **"Enable MCP bridge"** Option
is on, and pumped from the GUI frame loop. It binds `127.0.0.1:8843`.

## Tools

45 tools (the authoritative list + parameters live in `src/index.ts`; a task-oriented
reference is `../skills/poe2-build/references/tool-cookbook.md`). By domain:

- **Read / analyze:** `gui_get_build` (identity + stats + passive point budget — note
  ascendancy used/total is the 8-point **cap**, not Trial-unlocked points), `gui_explain_stat`
  (per-stat breakdown), `gui_explain_skill` (per-skill hit/ailment/DPS breakdown; for
  multi-part skills like slams it enumerates the parts via `skillPartCount`/`skillParts` and
  reads a specific one with `part` — the DPS is part-specific), `gui_query_mods` (raw modifier
  DB; each mod's `gates` resolve its conditions + current truth, with both unconditional and
  as-applied-to-the-main-skill sums), `gui_get_stat_keys` (discover output keys),
  `compute_build_stats` (headless calc).
- **Discovery (read-only, "search before mutate"):** `gui_get_config`, `gui_get_skills`,
  `gui_get_items`, `gui_get_jewel_sockets`, `gui_get_tree_specs`, `gui_search_passives`
  (regular tree), `gui_search_ascendancy` (selected ascendancy), `gui_search_items` (unique DB),
  `gui_search_gems` (gem DB).
- **Passive tree:** `gui_set_passive` (regular tree alloc/dealloc, `dryRun`/`maxPath`/`maxRemoved`),
  `gui_set_ascendancy` (ascendancy nodes — separate 8-point budget), `gui_set_class`,
  `gui_socket_jewel`, `gui_set_tree_version`, `gui_select_spec`.
- **Items / gear:** `gui_add_item` (raw text or unique `name`), `gui_equip_item`,
  `gui_remove_item`, `gui_set_item_roll`, `gui_replace_item`.
- **Skills / gems:** `gui_set_main_skill` (group/active skill, and `part` to switch which part
  of a multi-part skill the DPS reflects), `gui_add_gem`, `gui_set_gem`, `gui_remove_gem`,
  `gui_create_socket_group`, `gui_set_socket_group`.
- **Config:** `gui_set_config`.
- **Live account / character (Phase A):** `gui_account_status` (signed-in check, no
  network — reads the persisted OAuth token), `gui_list_characters` (account character
  list), `gui_import_character` (import a real character's tree/jewels/items/skills into the
  live build, revertible via `gui_undo`). These wrap PoB's account API through the async-job
  bridge primitive (`jobPoll`); the user authorises **once** in PoB's Import tab.
- **Live trade (Phase B):** `gui_list_leagues`, `gui_currency_rates` (poe.ninja currency→divine,
  cached), `gui_search_trade_stats` (discover the stat-filter ids the search needs),
  `gui_search_trade` (explicit-criteria search → top listings with price + seller whisper),
  `gui_price_item` (estimate an equipped item's market price from comparable listings). Wrap
  PoB's `TradeQueryRequests`/`TradeQuery` (rate-limited) through the same job primitive; the
  request queue is pumped from the bridge each frame. Read/search only — never auto-trades.
- **Lifecycle / undo / optimize:** `gui_build_lifecycle` (new/save/saveAs),
  `gui_undo` / `gui_redo` (per-tab scope), `gui_optimize`.

## Develop

```bash
# Use the userland Linux Node (Windows Node can't exec the Linux luajit):
export PATH="$HOME/.local/node/node-v20.18.1-linux-x64/bin:$PATH"
npm install
npm run build        # tsc -> dist/
npm run smoke        # Node -> luajit -> stats (headless; no MCP client/GUI needed)
npm run dev          # watch mode
```

Live-GUI checks must run from **Windows Node** (WSL Linux can't reach the GUI's
`127.0.0.1:8843` in WSL2 NAT mode), with PoB running + the bridge Option on:

```bash
npm run build
"/mnt/c/Program Files/nodejs/node.exe" dist/smoke_bridge.js
```

Headless bridge-logic tests (from `../src`):

```bash
LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;" CI=true luajit ../pob2-mcp/plugins/pob2-mcp/server/lua/test_bridge.lua
```

Env overrides: `POB_LUAJIT`, `POB_ROOT`, `POB_HEADLESS_RUNNER`, `POB_BRIDGE_HOST`,
`POB_BRIDGE_PORT`.

## Packaging (ship)

`../scripts/build-dist.sh` cross-builds the single Windows `.exe` (esbuild bundle → Node
SEA blob via Windows `node.exe` → postject) and stages `dist/PathOfBuilding2-MCP/` (the
bridge-enabled PoB + `pob2-mcp.exe` + bundled `runtime/luajit.exe` + `mcp-lua/` runner +
`README.txt`). `../scripts/dev-update-local.sh` updates a local install in place.
See `WINDOWS-HEADLESS.md` for the native-Windows headless details.

## Companion skills

Three project skills under `../skills/` drive these tools and document the game:
`poe2-build` (the build-authoring workflow), `poe2-mechanics` (PoE2 concepts + real PoB
stat/config vocabulary), and `poe2-sync` (`/poe2-sync` — refresh the knowledge from patch
notes).

## Run as an MCP server

The client launches it over stdio. In dev (WSL), point at the Linux Node build:

```json
{
  "mcpServers": {
    "pob2": { "command": "node", "args": ["<repo>/mcp/dist/index.js"] }
  }
}
```

If the client runs on Windows in dev, invoke through WSL:
`"command": "wsl.exe", "args": ["node", "<repo>/mcp/dist/index.js"]`. The shipped product
instead points at the bundled `pob2-mcp.exe` (no Node required) — see `dist` README.txt.
