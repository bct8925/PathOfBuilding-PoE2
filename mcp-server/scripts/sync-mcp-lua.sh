#!/usr/bin/env bash
# Re-vendor the mcp-lua library into mcp-server/vendor/mcp-lua/mcp.
#
# The Lua MCP protocol library is developed in its own repo (default ~/Dev/mcp-lua)
# and vendored here so PoB2 ships self-contained (no luarocks / submodule). Run this
# after updating mcp-lua to pull the latest copy. Override the source with MCP_LUA_SRC.
set -euo pipefail

SRC="${MCP_LUA_SRC:-$HOME/Dev/mcp-lua}/mcp"
DEST_DIR="$(cd "$(dirname "$0")/.." && pwd)/vendor/mcp-lua"
DEST="$DEST_DIR/mcp"

if [[ ! -d "$SRC" ]]; then
  echo "error: mcp-lua source not found at $SRC (set MCP_LUA_SRC)" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST_DIR"
cp -r "$SRC" "$DEST"
echo "synced mcp-lua: $SRC -> $DEST"
