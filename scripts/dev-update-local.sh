#!/usr/bin/env bash
#
# dev-update-local.sh — update a LOCAL unzipped install in place, skipping the slow
# zip → copy → unzip round-trip.
#
# The server is plain Lua now (no exe to rebuild), so this just syncs the files that
# change into your install folder:
#   - src/                 (the PoB app + src/Modules/MCPBridge.lua) — incremental
#   - mcp-server/          (the Lua MCP server + vendored mcp-lua) — incremental
#   - runtime/             (the big binaries + luajit.exe) — only with --full
#
# Incremental copies use `cp -u` (copy only when newer / missing), so a normal update
# moves just whatever you edited.
#
# Usage:
#   scripts/dev-update-local.sh            # update the default install (below)
#   scripts/dev-update-local.sh --full     # also sync runtime/ (binaries)
#   POB_LOCAL_DEST="/mnt/c/path/to/PathOfBuilding2-MCP" scripts/dev-update-local.sh
#
# After it runs: reload PoB (Ctrl+F5) so it picks up the new MCPBridge.lua (cached),
# and restart your MCP client so it reloads the Lua server.
#
# Dev-only (runs in WSL); nothing here ships.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Your personal install. Override with POB_LOCAL_DEST=... to target another copy.
DEST="${POB_LOCAL_DEST:-/mnt/c/Users/brian/OneDrive/Desktop/PathOfBuilding2-MCP/PathOfBuilding2-MCP}"

FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

say() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }

# 1. Refuse to write anywhere that isn't an existing PoB-MCP install.
if [[ ! -d "$DEST" ]]; then
  echo "ERROR: install folder not found: $DEST" >&2
  echo "       run scripts/build-dist.sh and unzip the dist there once, or set POB_LOCAL_DEST=..." >&2
  exit 1
fi
if [[ ! -e "$DEST/manifest.xml" ]]; then
  echo "ERROR: $DEST doesn't look like a PathOfBuilding2-MCP install (no manifest.xml)." >&2
  exit 1
fi

# 2. Sync the Lua. Copied from the REPO (not a restaged dist) so mtimes only change on
#    files you actually edited, keeping `cp -u` cheap into OneDrive.
say "Updating src/ (PoB + MCPBridge Lua) — changed files only"
cp -ru "$REPO_ROOT/src/." "$DEST/src/"

say "Updating mcp-server/ (Lua MCP server + vendored mcp-lua) — changed files only"
mkdir -p "$DEST/mcp-server"
cp -ru "$REPO_ROOT/mcp-server/lua/."    "$DEST/mcp-server/lua/"
cp -ru "$REPO_ROOT/mcp-server/vendor/." "$DEST/mcp-server/vendor/"

cp -f "$REPO_ROOT/scripts/dist-README.txt" "$DEST/README.txt" 2>/dev/null || true

# 3. The big runtime/ binaries rarely change — sync only with --full, but always make
#    sure luajit.exe is present (it runs both the server and the headless backend).
if [[ "$FULL" == "1" ]]; then
  say "Updating runtime/ (--full) — changed files only"
  cp -ru "$REPO_ROOT/runtime/." "$DEST/runtime/"
elif [[ ! -e "$DEST/runtime/luajit.exe" && -e "$REPO_ROOT/runtime/luajit.exe" ]]; then
  say "runtime/luajit.exe missing at the install — copying it"
  mkdir -p "$DEST/runtime"
  cp -f "$REPO_ROOT/runtime/luajit.exe" "$DEST/runtime/luajit.exe"
fi

say "Done — updated $DEST"
echo "Next: reload PoB (Ctrl+F5) for the Lua change, and restart your MCP client to reload the server."
