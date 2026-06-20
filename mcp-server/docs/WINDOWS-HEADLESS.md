# Windows headless runtime — spike notes (OQ-1 / Requirements §9.3)

The optimize/search backend (`gui_optimize`) evaluates candidate builds **headlessly**
by spawning a Lua interpreter on `mcp/lua/run_headless.lua`. In dev (WSL) that
interpreter is the Linux `luajit`. The shipped product is **native Windows only**,
so it must run a **Windows `luajit.exe`** instead — never a WSL/Linux binary.

This doc records what the server already does to support that, what the one
remaining blocker is, and exactly how to finish the spike.

## What resolves automatically (done)

`mcp/src/config.ts` resolves the headless runtime relative to the **Windows
distribution**, with no WSL assumptions baked in:

- **Interpreter** (`LUAJIT`): `POB_LUAJIT` env → else a bundled
  `runtime/luajit.exe` if present → else `luajit` on `PATH` (the dev default).
  So the moment a `luajit.exe` is dropped into PoB's `runtime/` folder, the
  shipped server uses it; nothing else needs to change.
- **Distribution root** (`REPO_ROOT`): `POB_ROOT` env → else an upward search for
  the `src/HeadlessWrapper.lua` marker. Works both in dev (`mcp/dist` → repo root)
  and shipped (the exe sits in PoB's folder → that folder).
- **`LUA_PATH`**: points at `runtime/lua/` (the bundled pure-Lua libs).
- **`LUA_CPATH`**: platform default first (`;;`), then `runtime/?.<dll|so>` as a
  fallback. PoB's `Common.lua` hard-requires `lua-utf8` — the **only** compiled
  module the calc engine needs. On Windows that ships as `runtime/lua-utf8.dll`
  (already in the distribution); the cpath fallback finds it there. The extension
  is chosen per-platform so luajit never tries to `dlopen` a wrong-ABI binary
  (a `?.dll` entry on Linux would match `lua-utf8.dll` → "invalid ELF header").

So the **runtime wiring is complete and platform-correct**. Verified on Linux:
`gui_optimize`'s search half (`searchHeadless` → `run_headless.lua` → stats)
runs with `LUAJIT=luajit` and the new `LUA_CPATH` (the bundled Windows
`lua-utf8.dll` is correctly skipped in favour of the dev `.so`).

## RESOLVED (Phase 4, 2026-06-18): `luajit.exe` is bundled

The binary is in `runtime/luajit.exe` (checked into git like the other runtime
DLLs). PoB's own `runtime/lua51.dll` turned out to BE LuaJIT 2.1.1753364724 (a
vcpkg x64-windows build), and the matching `luajit.exe` already existed in that
same vcpkg tree (`vcpkg_installed/x64-windows/tools/luajit/luajit.exe`) — an exact
ABI match that dynamically imports `lua51.dll`, so it pairs with the bundled
`runtime/lua51.dll` + `runtime/lua-utf8.dll` with no collision (the headless luajit
runs as a SEPARATE process from the GUI's in-process VM). Verified end-to-end:
compute + search (the optimize backend) run the full calc engine and return real
stats, both from the repo and from the staged dist in shipped layout. The notes
below are retained for the record / for rebuilding the binary if ever needed.

LuaJIT is **ABI-compatible with Lua 5.1**, and PoB already ships a Lua-5.1-built
`runtime/lua-utf8.dll`, so a stock LuaJIT for Windows x64 loads it as-is — no
recompiling the compiled dep.

### To rebuild/replace the binary

1. **Obtain a LuaJIT for Windows x64.** Either:
   - download a prebuilt `luajit.exe` + `lua51.dll` for x64 (LuaJIT 2.1), or
   - build from the LuaJIT source with MSVC: `cd src && msvcbuild.bat` (x64
     Native Tools prompt) → produces `luajit.exe` + `lua51.dll`.
   Note PoB already ships a `runtime/lua51.dll`; if the LuaJIT `luajit.exe`
   expects its own `lua51.dll`, ship LuaJIT's alongside it under a name that
   doesn't collide with PoB's GUI VM (e.g. keep luajit + its lua51 in a
   `runtime/headless/` subdir and set `POB_LUAJIT` / the bundled-path lookup to it).
2. **Drop it in** `runtime/luajit.exe` (or point `POB_LUAJIT` at it).
3. **Verify** from a Windows shell (engine boot + a search round-trip):
   ```bat
   cd <PoB>\src
   set LUA_PATH=..\runtime\lua\?.lua;..\runtime\lua\?\init.lua;;
   set LUA_CPATH=;;..\runtime\?.dll
   set CI=true
   echo {"action":"compute"} | ..\runtime\luajit.exe ..\mcp\lua\run_headless.lua
   ```
   Expect a `@@POB_RESULT@@{...,"ok":true,...}` line with real stats. Then run the
   Node search path on Windows Node with `POB_LUAJIT` set to the same exe.
4. **Confirm stat parity** with the Linux engine for the same build XML (the calc
   core is identical Lua; only the interpreter differs).

### OQ-1 resolution (CLOSED)

v1 **ships a dedicated `runtime/luajit.exe`** (this doc). Reusing PoB's in-process
`lua51.dll` / SimpleGraphic to avoid a second binary stays deferred — the bundled
`luajit.exe` is the simpler, lower-risk path. The only compiled dependency
(`lua-utf8.dll`) is already in the distribution and is ABI-loadable by LuaJIT, so
no extra native build is required.

## Packaging follow-up (Phase 4 / OQ-6) — DONE

`config.ts` `resolveHeadlessRunner()` resolves `run_headless.lua` at
`<POB_ROOT>/mcp-lua/run_headless.lua` in the shipped layout (dev:
`<repo>/mcp/lua/run_headless.lua`; override: `POB_HEADLESS_RUNNER`) — it no longer
depends on `here/../lua`, which is wrong in the SEA exe (`here` = install folder).
`scripts/build-dist.sh` stages `mcp-lua/run_headless.lua` and asserts
`runtime/luajit.exe` made it into the staged `runtime/` (which also carries
`lua51.dll` + `lua-utf8.dll`). `resolveLuajit()` prefers the bundled
`runtime/luajit.exe` only on `win32` so the Linux dev box keeps using PATH `luajit`.
