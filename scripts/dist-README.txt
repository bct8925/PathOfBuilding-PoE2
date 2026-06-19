================================================================================
 Path of Building 2  +  MCP server
================================================================================

This is Path of Building 2 (the PoE2 build planner) with a built-in "MCP bridge"
that lets an AI assistant inspect and modify your live build, plus a small server
(pob2-mcp.exe) that connects your MCP client to it.

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
client so it picks up the server. No other setup is needed — the server finds
Path of Building, its Lua engine, and the bundled headless interpreter relative
to its own folder.


--------------------------------------------------------------------------------
 4. What the assistant can do
--------------------------------------------------------------------------------
With Path of Building running and the bridge enabled, these tools operate on
your live build and the results appear in the GUI immediately. Every mutation
recalculates and the refreshed stats come straight back; use gui_undo to revert
anything the assistant does (it drives PoB's own undo stack).

  Read / explain
    gui_get_build       - identity (class, ascendancy, level, main skill) and
                          computed stats (DPS, Life/ES/Mana, EHP, resistances,
                          crit, …)
    gui_explain_stat    - break down where a stat's value comes from (the
                          contributing modifiers)

  Edit the build (applied live, recalculated, undoable)
    gui_set_class       - set class / ascendancy
    gui_set_passive     - allocate / deallocate a passive-tree node
    gui_set_config      - toggle or set a Configuration-tab option
    gui_set_main_skill  - choose the main skill group
    gui_add_gem / gui_set_gem / gui_remove_gem
                        - manage skill gems in a group
    gui_add_item / gui_equip_item / gui_remove_item / gui_set_item_roll
                        - manage items and their rolled modifier values

  History
    gui_undo / gui_redo - step through PoB's native undo stack

  Optimize / search
    gui_optimize        - the assistant proposes candidate change-sets; the
                          server snapshots your live build, evaluates each
                          candidate HEADLESSLY (using the bundled luajit.exe),
                          scores them against your objective + constraints, and
                          applies the winning change-set back to the live build.

  Headless (no GUI needed)
    compute_build_stats - compute stats for a build snapshot off-GUI, via the
                          bundled luajit.exe.

The optimize and headless tools run the bundled runtime\luajit.exe against the
same Lua calc engine the GUI uses — no separate install, and the numbers match
the GUI.


--------------------------------------------------------------------------------
 Troubleshooting
--------------------------------------------------------------------------------
- "could not reach PoB GUI bridge ...": make sure Path of Building is running,
  a build is open, and "Enable MCP bridge" is ticked in Options.
- Windows SmartScreen may warn on first launch of pob2-mcp.exe (it's an
  unsigned build). Choose "More info" > "Run anyway".
- gui_optimize / compute_build_stats fail with a "luajit" error: confirm
  runtime\luajit.exe is present in this folder (it ships the headless engine).

================================================================================
