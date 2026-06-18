================================================================================
 Path of Building 2  +  MCP server  (Phase 1)
================================================================================

This is Path of Building 2 (PoE2 build planner) with a built-in "MCP bridge"
that lets an AI assistant inspect and modify your live build, plus a small
server (pob2-mcp.exe) that connects your MCP client to it.

Requirements: 64-bit Windows. Nothing else — no Node, no install, no toolchain.
Everything needed is in this folder. The server (pob2-mcp.exe) and Path of
Building must run on the SAME Windows machine (the bridge is local-only).


--------------------------------------------------------------------------------
 1. Run Path of Building
--------------------------------------------------------------------------------
Open the "runtime" folder and double-click the Path of Building executable
("Path of Building-PoE2"). The build planner opens as usual.


--------------------------------------------------------------------------------
 2. Turn on the MCP bridge  (off by default)
--------------------------------------------------------------------------------
In Path of Building:
  - Click "Options" (bottom-left).
  - Tick "Enable MCP bridge".
  - Click "Save".

Path of Building now listens locally on 127.0.0.1:8843 for the MCP server.
The setting is remembered between sessions. Untick it any time to turn the
bridge off. A build must be open (not the build list) for the bridge to serve
requests.


--------------------------------------------------------------------------------
 3. Point your MCP client at the server
--------------------------------------------------------------------------------
pob2-mcp.exe is a standard stdio MCP server. Add it to your MCP client's
config with the FULL path to pob2-mcp.exe in this folder. Example (Claude
Desktop / Claude Code — claude_desktop_config.json):

  {
    "mcpServers": {
      "pob2": {
        "command": "C:\\path\\to\\PathOfBuilding2-MCP\\pob2-mcp.exe"
      }
    }
  }

Replace C:\\path\\to\\... with where you unzipped this folder. Restart the
client so it picks up the server.


--------------------------------------------------------------------------------
 4. What the assistant can do (Phase 1)
--------------------------------------------------------------------------------
With Path of Building running and the bridge enabled, these tools operate on
your live build and the results appear in the GUI immediately:

  gui_get_build   - read identity (class, ascendancy, level, main skill) and
                    computed stats (DPS, Life/ES/Mana, EHP, resistances, crit…)
  gui_set_config  - toggle/set a Configuration-tab option, then recalc
  gui_set_passive - allocate/deallocate a passive-tree node, then recalc
  gui_undo        - undo the last change (PoB's native undo)
  gui_redo        - redo

Every change recalculates and the refreshed stats come straight back. Use
gui_undo to revert anything the assistant does.


--------------------------------------------------------------------------------
 Troubleshooting
--------------------------------------------------------------------------------
- "could not reach PoB GUI bridge ...": make sure Path of Building is running,
  a build is open, and "Enable MCP bridge" is ticked in Options.
- Windows SmartScreen may warn on first launch of pob2-mcp.exe (it's an
  unsigned build). Choose "More info" > "Run anyway".
- The compute_build_stats tool (headless calc) is not active in this build;
  it arrives in a later phase. The live gui_* tools above are the Phase 1 set.

================================================================================
