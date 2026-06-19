#!/usr/bin/env bash
#
# dev-update-local.sh — rebuild the MCP server and update a LOCAL unzipped install
# in place, skipping the slow zip → copy → unzip round-trip.
#
# It runs the real packaging (scripts/build-dist.sh, SKIP_ZIP) so what you get is
# byte-for-byte what a shipped dist contains, then copies the pieces that actually
# change into your install folder:
#   - pob2-mcp.exe         (rebuilt every run)
#   - src/                 (the PoB app + src/Modules/MCPBridge.lua) — incremental
#   - mcp-lua/             (the headless runner)
#   - runtime/             (the big binaries + luajit.exe) — only with --full
#
# Incremental copies use `cp -u` (copy only when newer / missing), so a normal
# update moves the exe + whatever Lua you edited, not the whole tree.
#
# Usage:
#   scripts/dev-update-local.sh            # update the default install (below)
#   scripts/dev-update-local.sh --full     # also sync runtime/ (binaries) — first
#                                          # setup or after a runtime/ change
#   POB_LOCAL_DEST="/mnt/c/path/to/PathOfBuilding2-MCP" scripts/dev-update-local.sh
#
# After it runs: reload PoB (Ctrl+F5) so it picks up the new MCPBridge.lua (the
# module is cached), and restart your MCP client so it loads the new exe.
#
# Dev-only (runs in WSL); nothing here ships.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$REPO_ROOT/dist/PathOfBuilding2-MCP"

# Your personal install. Override with POB_LOCAL_DEST=... to target another copy.
DEST="${POB_LOCAL_DEST:-/mnt/c/Users/brian/OneDrive/Desktop/PathOfBuilding2-MCP/PathOfBuilding2-MCP}"

FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

say() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }

# 1. Build the exe + stage the dist via the real packaging (no zip).
SKIP_ZIP=1 "$REPO_ROOT/scripts/build-dist.sh"

# 2. Refuse to write anywhere that isn't an existing PoB-MCP install (don't create
#    a half-populated folder from a typo'd path).
if [[ ! -d "$DEST" ]]; then
  echo "ERROR: install folder not found: $DEST" >&2
  echo "       unzip the dist there once, or set POB_LOCAL_DEST=... to your copy." >&2
  exit 1
fi
if [[ ! -e "$DEST/manifest.xml" && ! -e "$DEST/pob2-mcp.exe" ]]; then
  echo "ERROR: $DEST doesn't look like a PathOfBuilding2-MCP install" >&2
  echo "       (no manifest.xml / pob2-mcp.exe). Refusing to write there." >&2
  exit 1
fi

# 3. Sync the Lua FIRST. This is what PoB picks up on Ctrl+F5, and it's
#    independent of the exe — so a locked exe (below) never blocks it. Copied from
#    the REPO (not the freshly-restaged dist) because the stage gets brand-new
#    mtimes every run, which would make `cp -u` re-copy the whole tree into
#    OneDrive each time; repo mtimes only change on files you actually edited.
say "Updating src/ (PoB + MCPBridge Lua) — changed files only"
cp -ru "$REPO_ROOT/src/." "$DEST/src/"

say "Updating mcp-lua/ + README"
cp -f "$REPO_ROOT/mcp/lua/run_headless.lua" "$DEST/mcp-lua/run_headless.lua"
cp -f "$REPO_ROOT/scripts/dist-README.txt" "$DEST/README.txt" 2>/dev/null || true

# 4. The big runtime/ binaries rarely change — sync only with --full, but always
#    make sure the headless interpreter is present (gui_optimize needs it).
if [[ "$FULL" == "1" ]]; then
  say "Updating runtime/ (--full) — changed files only"
  cp -ru "$REPO_ROOT/runtime/." "$DEST/runtime/"
elif [[ ! -e "$DEST/runtime/luajit.exe" && -e "$REPO_ROOT/runtime/luajit.exe" ]]; then
  say "runtime/luajit.exe missing at the install — copying it"
  mkdir -p "$DEST/runtime"
  cp -f "$REPO_ROOT/runtime/luajit.exe" "$DEST/runtime/luajit.exe"
fi

# 5. The exe LAST. A running MCP client (or PoB) holds pob2-mcp.exe open on
#    Windows, so the copy fails with an I/O error. Don't abort the whole update for
#    that — the Lua above already landed; flag it and say what to do. (Guarded `if`
#    so `set -e` doesn't kill the script on a locked exe.)
say "Updating pob2-mcp.exe"
EXE_OK=1
cp -f "$STAGE/pob2-mcp.exe" "$DEST/pob2-mcp.exe" 2>/dev/null || EXE_OK=0

if [[ "$EXE_OK" == "1" ]]; then
  say "Done — updated $DEST"
  echo "Next: reload PoB (Ctrl+F5) for the Lua change, and restart your MCP client for the new exe."
else
  printf '\n\033[33m==> Partial update: src/ Lua synced, but pob2-mcp.exe is LOCKED.\033[0m\n'
  echo   "    Your MCP client (or PoB) is holding it open. The new TOOLS need the exe, so:"
  echo   "      1) stop your MCP client,  2) re-run this script  (the Lua is already updated)."
  echo   "    Reload PoB (Ctrl+F5) regardless to pick up the Lua change."
  exit 1
fi
