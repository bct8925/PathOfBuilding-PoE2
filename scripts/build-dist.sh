#!/usr/bin/env bash
#
# build-dist.sh — produce a self-contained, sendable Windows distribution of
# Path of Building 2 + the MCP server.
#
# Output: dist/PathOfBuilding2-MCP/ (and a .zip) containing:
#   - the bridge-enabled PoB2 (runtime/ + src/ + manifest)
#   - mcp-server/    : the Lua MCP server (mcp_server.lua + lua/ + vendored mcp-lua)
#   - README.txt     : setup + MCP-client config for the recipient
#
# The server is plain Lua now — there is NO build/compile step and NO Node toolchain.
# The bundled runtime/luajit.exe runs BOTH the MCP server and the headless calc engine.
# This script just stages files. It is dev-only (runs in WSL); nothing here leaks into
# the product — the product is the dist/ folder.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/dist"
STAGE="$DIST/PathOfBuilding2-MCP"

say() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }

# --- stage the distribution folder -------------------------------------------
say "Staging distribution at $STAGE"
rm -rf "$STAGE"; mkdir -p "$STAGE"

# PoB2 application (the proven runtime/ + src/ sibling layout). runtime/ carries the
# Windows luajit.exe + lua51.dll + lua-utf8.dll + pure-Lua libs (dkjson/socket/sha1).
cp -r "$REPO_ROOT/runtime" "$STAGE/runtime"
cp -r "$REPO_ROOT/src"     "$STAGE/src"
cp "$REPO_ROOT/manifest.xml"  "$STAGE/manifest.xml"
cp "$REPO_ROOT/changelog.txt" "$STAGE/changelog.txt" 2>/dev/null || true
cp "$REPO_ROOT/help.txt"      "$STAGE/help.txt" 2>/dev/null || true

# The Lua MCP server: entry + modules + vendored mcp-lua + the headless runner. Skip
# the test/ and docs/ trees (not needed at runtime).
say "Staging mcp-server/ (Lua server + vendored mcp-lua)"
mkdir -p "$STAGE/mcp-server"
cp "$REPO_ROOT/mcp-server/mcp_server.lua" "$STAGE/mcp-server/mcp_server.lua"
cp -r "$REPO_ROOT/mcp-server/lua"         "$STAGE/mcp-server/lua"
cp -r "$REPO_ROOT/mcp-server/vendor"      "$STAGE/mcp-server/vendor"

cp "$REPO_ROOT/scripts/dist-README.txt" "$STAGE/README.txt" 2>/dev/null || true

# The bundled luajit.exe runs both the server and the headless backend. Assert it
# landed so the dist is honest about whether the server/optimize will work on Windows.
if [[ -f "$STAGE/runtime/luajit.exe" ]]; then
  say "Interpreter: bundled runtime/luajit.exe ($("$STAGE/runtime/luajit.exe" -v 2>/dev/null | head -1 | tr -d '\r'))"
else
  printf '\n\033[33mWARNING: runtime/luajit.exe is missing — the MCP server AND gui_optimize/headless\n         will be INERT in this dist. Drop an ABI-matched LuaJIT 2.1 x64 luajit.exe\n         into runtime/ and rebuild.\033[0m\n'
fi

# --- zip it ------------------------------------------------------------------
# Set SKIP_ZIP=1 to leave just the staged folder (used by dev-update-local.sh).
if [[ "${SKIP_ZIP:-0}" == "1" ]]; then
  say "Done (SKIP_ZIP — staged folder only)"
  du -sh "$STAGE"
  echo "Staged distribution: $STAGE"
else
  say "Zipping"
  ( cd "$DIST" && rm -f PathOfBuilding2-MCP.zip && \
    zip -rq PathOfBuilding2-MCP.zip PathOfBuilding2-MCP )
  say "Done"
  du -sh "$STAGE" "$DIST/PathOfBuilding2-MCP.zip"
  echo "Distribution: $DIST/PathOfBuilding2-MCP.zip"
fi
