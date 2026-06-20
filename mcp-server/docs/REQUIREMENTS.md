# PoB2 MCP — Requirements (v1)

Status: **v1 delivered** (all FRs implemented; dev-verified, native-Windows acceptance
pending) · Last updated: 2026-06-19 · Owner: @bri64 · Branch: `bri64-mcp`

> **Implementation status.** All four phases (§9) are done and the full FR surface ships
> as **37 MCP tools** (`mcp/src/index.ts`), covered by 200+ headless checks
> (`mcp/lua/test_bridge.lua`) + a live-GUI smoke (`mcp/src/smoke_bridge.ts`). FR-8
> (passive tree) is fully closed incl. tree-version switching; discovery readers exist for
> every mutate domain (tree/items/uniques/gems/config), so the AI searches before mutating.
> Beyond the original spec, two real-usage feedback rounds were folded in (see
> `mcp/ISSUES.md`, `SUMMARY.md`): point-budget readout, safe-deallocation dry-run/guards,
> config pagination, stat-key discovery, gem browser, and `gui_explain_skill` (per-skill
> hit/ailment/DPS breakdown). Open: OQ-5 (concurrency) and the final native-Windows SEA-exe +
> live-GUI acceptance pass.

## 1. Goal

Provide an MCP server that lets an AI assistant **analyze, improve, optimize, and
author** Path of Building 2 builds, primarily by **driving a live, running PoB2
GUI** so changes appear on screen immediately.

## 2. Users, client & distribution

- **Shipped target is native Windows only.** It must feel like a **natural,
  built-in extension to PoB** — no WSL, no Node install, and no separate toolchain
  expected of the end user. WSL is **purely our dev environment** and must not leak
  into the shipped product or its assumptions.
- The MCP server is **plain Lua** (in the PoB2 repo at `mcp-server/`, built on the
  `mcp-lua` library) run by the bundled **Windows `luajit.exe`** — no Node, no build
  step, no extra runtime on the user's machine. (Historically it was Node/TypeScript
  packaged as a Node-SEA `.exe`; it was migrated to Lua so one interpreter serves both
  the server and the headless backend.)
- **Client-agnostic:** the server speaks MCP over stdio; we provide a documented
  config snippet so the user can wire it into whatever MCP client they use (Claude
  Desktop, Claude Code, etc.). Dev is driven from local Claude Code.
- **Headless runtime on Windows:** ship a **Windows `luajit.exe`** with the
  distribution for the headless/search backend (reusing PoB's bundled `lua51.dll`
  is deferred — see OQ-1).

## 3. Scope

**In scope (v1)**
- Live-GUI control of the **currently open build**: read, mutate, recalc.
- Build lifecycle limited to **new / save / save-as** on the current build.
- All four use cases: analyze, suggest, optimize/search, authoring.
- Mutation of passive tree, items/gear, skills/gems, and config options.
- Optimization with an **AI-chosen objective per request**.
- Analysis exposing **final stats + per-stat breakdowns**.

- **Distribution:** server ships as a single Windows `.exe` inside PoB's folder;
  a Windows `luajit.exe` ships for headless; a config snippet documents client
  wiring.

**Out of scope (v1)**
- External imports: PoB import codes/URLs, PoE account character import, trade
  integration. (Operate only on builds already in PoB.)
- Opening arbitrary saved builds by name / browsing the build library.
- Auto-launching the GUI; multi-user or remote operation.
- Requiring WSL, a user Node install, or any dev toolchain on the user's machine.

## 4. Functional requirements

### 4.1 Backends
- **FR-1 (Live GUI — primary).** Connect to a running PoB2 instance via the in-app
  socket bridge and read/mutate its in-memory build state. All v1 user-facing
  features are available against the live GUI.
- **FR-2 (Already-running only).** The MCP **does not launch** PoB. If no live
  instance with the bridge is reachable, tools fail with a clear, actionable error.
- **FR-3 (Search backend).** Optimization/search runs trials **off the visible
  build** and applies only the winner live (see FR-13). It should not make the GUI
  visibly churn through every trial.

### 4.2 Read / analyze
- **FR-4.** Read the live build's identity (class, ascendancy, level, main skill).
- **FR-5.** Read final computed stats (DPS variants, Life/ES/Mana/Ward, resistances,
  crit, speed, etc.).
- **FR-6.** Expose **per-stat breakdowns** — how a value was derived (contributing
  mods/multipliers), comparable to PoB's Calcs-tab breakdown.
- **FR-7.** Support targeted "why" queries against the modifier database (e.g. sum
  of INC/MORE for a stat with given flags). *(Stretch within v1.)*

### 4.3 Mutation (applies to the live build, recalc + redraw after each)
- **FR-8 (Passive tree).** Allocate / deallocate nodes; swap jewels; change
  class/ascendancy and tree version.
- **FR-9 (Items / gear).** Add, equip, remove, and edit items; adjust rolls.
- **FR-10 (Skills / gems).** Set the main skill; add/remove support gems; change
  gem level/quality.
- **FR-11 (Config).** Toggle Configuration-tab options (buffs, enemy settings,
  conditions) that drive the calc.
- **FR-12 (Immediate apply + recalc).** Every mutation applies immediately to the
  live build, triggers a recalc, and returns the refreshed stats.

### 4.4 Optimization / search
- **FR-13.** Given an AI-chosen objective (single metric, weighted blend, or with
  constraints — decided per request), evaluate many variations across tree / gear /
  gems / config, then **apply the best result to the live build**.
- **FR-14.** Report the chosen objective, the search space considered, and the
  stat deltas of the applied winner.

### 4.5 Build authoring
- **FR-15.** Create a new build (class/ascendancy, level) and populate tree, skills,
  items, and config from a natural-language goal, using the mutation primitives.

### 4.6 Lifecycle & undo
- **FR-16 (Lifecycle).** Support **new build**, **save**, and **save-as** on the
  current build. No arbitrary open-by-name in v1.
- **FR-17 (Undo).** Reverting AI changes uses **PoB's native undo/redo stack** (the
  same mechanism as the GUI's undo). The MCP can trigger undo/redo; granularity
  matches PoB's.
- **FR-18 (Safety).** Changes apply immediately (no pre-apply confirmation gate);
  recoverability is provided by FR-17. Tools should report what they changed.

### 4.7 Bridge enablement
- **FR-19.** The socket bridge is **built into PoB2's source**, gated behind an
  **Options toggle** (e.g. "Enable MCP bridge"). When enabled, PoB listens on a
  local port and pumps the bridge from its frame loop. Off by default.

## 5. Proposed MCP tool surface (derived from FRs)

| Tool | Purpose | FRs |
|---|---|---|
| `get_build` | Identity + final stats of the live build | 4,5 |
| `explain_stat` | Breakdown / derivation for a named stat | 6,7 |
| `set_passive` | Allocate/deallocate nodes, jewels, class/tree | 8 |
| `edit_item` | Add/equip/remove/edit gear | 9 |
| `set_skill` | Main skill + supports + gem level/quality | 10 |
| `set_config` | Toggle/set configuration options | 11 |
| `optimize` | Search to an objective; apply winner | 13,14 |
| `author_build` | Create+populate a build from a goal | 15 |
| `build_lifecycle` | new / save / save-as | 16 |
| `undo` / `redo` | Drive PoB's native undo stack | 17 |

(Names indicative; final granularity TBD during design.)

## 6. Non-functional requirements
- **NFR-1 (Native Windows ship target).** The shipped server + bridge + headless
  runtime run on native Windows with **zero user prerequisites** (no Node, no WSL,
  no toolchain). WSL is dev-only and must not leak into the product.
- **NFR-2 (Self-contained packaging).** Server distributed as a single Windows
  `.exe`; `luajit.exe` bundled for headless. Lives inside PoB's folder.
- **NFR-3 (Natural extension).** Setup should feel built-in: enable a toggle in
  PoB, point the MCP client at the bundled server. Minimal manual steps.
- **NFR-4 (Responsiveness).** Single read/mutate round-trips feel interactive
  (sub-second target excluding heavy recalcs).
- **NFR-5 (Robustness).** Clear errors when the GUI/bridge is unavailable; the
  bridge must never block or crash the GUI frame loop.
- **NFR-6 (Non-invasive default).** Bridge off unless the user enables it.

## 7. Architecture decisions (recap)
- Lua MCP server (`mcp-server/`, on the vendored `mcp-lua` library); stdio transport;
  launched by local Claude Code as `luajit mcp_server.lua`. (Migrated from the original
  Node/TS server; the gui_* tools forward to the same `MCPBridge.lua` handlers.)
- Live GUI bridge: in-app Lua socket server, newline-delimited JSON
  (`{id,method,params}` → `{id,ok,result|error}`), pumped from `OnFrame`. The server's
  `mcp-server/lua/bridge.lua` is the LuaSocket client.
- Headless/search backend: `mcp-server/lua/engine.lua` spawns `luajit` on
  `mcp-server/lua/run_headless.lua`.

## 8. Open questions / risks
- **OQ-1 (Reuse bundled Lua — deferred).** ✅ RESOLVED for v1: ships an ABI-matched Windows
  `luajit.exe` (PoB's `lua51.dll` is itself LuaJIT 2.1). Reusing the DLL directly remains a
  future enhancement, not a blocker.
- **OQ-6 (Packaging toolchain).** ✅ RESOLVED: Node SEA via `scripts/build-dist.sh` (esbuild
  bundle → SEA blob with a version-matched Windows `node.exe` → postject), staging the runner
  + `luajit.exe` and resolving PoB's `src/` relative to the exe.
- **OQ-2 (WSL ↔ Windows networking).** ✅ RESOLVED: WSL Linux cannot reach the GUI's
  `127.0.0.1:8843` under WSL2 NAT — so the client runs Windows-side (the shipped model);
  dev drives the live bridge from Windows Node. No cross-OS networking in the product.
- **OQ-3 (Undo granularity).** ✅ RESOLVED: PoB's per-tab undo cleanly reverts each mutation
  (scope tree/items/skills/config). Note: tree-VERSION conversions are a structural specList
  op reverted via `gui_select_spec`, not `gui_undo` (documented on the tool).
- **OQ-4 (Optimization apply-from-search).** ✅ RESOLVED: the winning candidate is a SEMANTIC
  op-list replayed through the same mutator handlers live (`applyChangeSet`), with SHA1 drift
  detection vs the snapshot — identical trial/live code path.
- **OQ-5 (Concurrency).** ⏳ OPEN: behavior with multiple PoB instances (v1 assumes one).

## 9. Phasing — all delivered ✅
1. ✅ **Live bridge MVP** — built-in bridge + Options toggle (FR-19); get_build, set_config,
   set_passive; undo (FR-17).
2. ✅ **Full mutation** — items, skills, breakdowns (FR-6), lifecycle save.
3. ✅ **Optimize/search + authoring** — Windows `luajit.exe` headless, OQ-4, FR-13/15.
4. ✅ **Packaging & ship** — single Windows `.exe` (OQ-6) + bundled `luajit.exe`/runner in
   PoB's folder, client config snippet, Options toggle wired end to end (NFR-1/2/3). The
   final native-Windows SEA-exe + live-GUI acceptance run is the remaining step.

**Post-v1 tiers shipped** (beyond the original spec): tree-version switching
(`gui_get_tree_specs`/`gui_set_tree_version`/`gui_select_spec`), unique item browser
(`gui_search_items` + add-by-name), gem browser (`gui_search_gems`), and two real-usage
feedback rounds (`ISSUES.md`, `SUMMARY.md`): point budget, safe-deallocation dry-run +
`maxRemoved`, config pagination/`modifiedOnly`, stat-key discovery, socket-group create/set,
and **`gui_explain_skill`** (per-skill hit-by-type / crit / speed / hit+DoT DPS / ailment
chance+buildup — reads a non-main group without switching the live main skill).

Note: throughout dev, keep the WSL path working but **never bake WSL assumptions
into the product** — paths, runtimes, and launch must resolve relative to the
Windows distribution.
