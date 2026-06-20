#!/usr/bin/env bash
#
# build-dist.sh — produce a self-contained, sendable Windows distribution of
# Path of Building 2 + the MCP server.
#
# Output: dist/PathOfBuilding2-MCP/ (and a .zip) containing:
#   - the MCP-server-enabled PoB2 (runtime/ + src/ + manifest)
#   - mcp-server/    : the Lua MCP server PoB hosts in-process (lua/ + vendored mcp-lua)
#   - README.txt     : setup + MCP-client config for the recipient
#
# The MCP server is plain Lua hosted INSIDE PoB over HTTP (enable it in Options); the
# client connects to http://127.0.0.1:8843/mcp — nothing is spawned. There is NO
# build/compile step and NO Node toolchain. The bundled runtime/luajit.exe runs the
# headless calc engine (gui_optimize/compute, via a background LaunchSubScript). This
# script just stages files; it is dev-only (runs in WSL) and nothing here leaks into
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

# The Lua MCP server PoB loads in-process: tool registry + vendored mcp-lua + the
# headless runner. Skip the test/ and docs/ trees (not needed at runtime).
say "Staging mcp-server/ (Lua MCP server + vendored mcp-lua)"
mkdir -p "$STAGE/mcp-server"
cp -r "$REPO_ROOT/mcp-server/lua"    "$STAGE/mcp-server/lua"
cp -r "$REPO_ROOT/mcp-server/vendor" "$STAGE/mcp-server/vendor"

cp "$REPO_ROOT/scripts/dist-README.txt" "$STAGE/README.txt" 2>/dev/null || true

# The bundled luajit.exe runs the headless backend (gui_optimize/compute). Assert it
# landed so the dist is honest about whether optimize/headless will work on Windows.
# (The MCP server itself runs inside PoB and needs no separate interpreter.)
if [[ -f "$STAGE/runtime/luajit.exe" ]]; then
  say "Headless interpreter: bundled runtime/luajit.exe ($("$STAGE/runtime/luajit.exe" -v 2>/dev/null | head -1 | tr -d '\r'))"
else
  printf '\n\033[33mWARNING: runtime/luajit.exe is missing — gui_optimize/headless will be INERT\n         in this dist. Drop an ABI-matched LuaJIT 2.1 x64 luajit.exe into runtime/ and rebuild.\033[0m\n'
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
