#!/usr/bin/env bash
#
# build-dist.sh — produce a self-contained, sendable Windows distribution of
# Path of Building 2 + the Phase 1 MCP server.
#
# Output: dist/PathOfBuilding2-MCP/ (and a .zip) containing:
#   - the bridge-enabled PoB2 (runtime/ + src/ + manifest)
#   - pob2-mcp.exe   : the MCP server as a single self-contained Windows exe
#                      (Node embedded via SEA — no Node required on the target)
#   - README.txt     : setup + MCP-client config for the recipient
#
# This is a DEV-ONLY build tool (it runs in WSL). It cross-builds the Windows
# exe using the Linux Node toolchain for bundling + a Windows node.exe for the
# SEA blob (whose format is version-specific). Nothing here leaks into the
# shipped product; the product is the dist/ folder.
#
# Prereqs (all already present in this dev env):
#   - Linux Node on PATH (userland: ~/.local/node/.../bin)
#   - a Windows node.exe reachable (for SEA blob generation)
#   - npx esbuild + postject (installed as mcp/ devDependencies)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP="$REPO_ROOT/mcp"
DIST="$REPO_ROOT/dist"
STAGE="$DIST/PathOfBuilding2-MCP"
BUILD="$MCP/build"
SEA_FUSE_PREFIX="NODE_SEA_FUSE_"

say() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }

# --- locate the Windows node.exe (needed for the version-matched SEA blob) ----
WIN_NODE="${WIN_NODE:-}"
if [[ -z "$WIN_NODE" ]]; then
  if command -v node.exe >/dev/null 2>&1; then
    WIN_NODE="$(command -v node.exe)"
  elif [[ -x "/mnt/c/Program Files/nodejs/node.exe" ]]; then
    WIN_NODE="/mnt/c/Program Files/nodejs/node.exe"
  else
    echo "ERROR: could not find a Windows node.exe (set WIN_NODE=...)." >&2
    exit 1
  fi
fi
say "Windows node.exe: $WIN_NODE ($("$WIN_NODE" -v 2>/dev/null | tr -d '\r'))"

# --- 1. bundle the TypeScript server into a single CJS file -------------------
say "Bundling server (esbuild -> CJS)"
mkdir -p "$BUILD"
( cd "$MCP" && npx esbuild src/index.ts --bundle --platform=node --format=cjs \
    --target=node20 \
    --banner:js="const _importMetaUrl=require('url').pathToFileURL(__filename).href;" \
    --define:import.meta.url=_importMetaUrl \
    --outfile=build/bundle.cjs )

# --- 2. generate the SEA blob with the Windows node (format is version-bound) -
# Run in a Windows-accessible dir so the Windows node process can read/write it.
say "Generating SEA blob (Windows node)"
WIN_WORK="/mnt/c/Temp/pob2-mcp-sea"
rm -rf "$WIN_WORK"; mkdir -p "$WIN_WORK"
cp "$BUILD/bundle.cjs" "$WIN_WORK/bundle.cjs"
cat > "$WIN_WORK/sea-config.json" <<'JSON'
{ "main": "bundle.cjs", "output": "sea-prep.blob", "disableExperimentalSEAWarning": true }
JSON
( cd "$WIN_WORK" && "$WIN_NODE" --experimental-sea-config sea-config.json )
cp "$WIN_WORK/sea-prep.blob" "$BUILD/sea-prep.blob"

# --- 3. inject the blob into a copy of node.exe (postject) --------------------
# The SEA fuse sentinel differs by Node version, so read it from the binary.
say "Injecting blob into node.exe -> pob2-mcp.exe"
FUSE="$(strings -n 10 "$WIN_NODE" | grep -oE "${SEA_FUSE_PREFIX}[0-9a-f]+" | head -1)"
if [[ -z "$FUSE" ]]; then
  echo "ERROR: could not read SEA fuse sentinel from $WIN_NODE" >&2
  exit 1
fi
echo "    fuse: $FUSE"
# Copy via cat so the result is writable (the source node.exe is read-only and
# WSL can't chmod files on /mnt/c).
cat "$WIN_NODE" > "$BUILD/pob2-mcp.exe"
chmod 755 "$BUILD/pob2-mcp.exe"
( cd "$MCP" && npx postject build/pob2-mcp.exe NODE_SEA_BLOB build/sea-prep.blob \
    --sentinel-fuse "$FUSE" )
# Note: patching the PE invalidates node.exe's Authenticode signature (postject
# warns). That's expected; the exe runs (SmartScreen may prompt on first launch).

# --- 4. stage the distribution folder ----------------------------------------
say "Staging distribution at $STAGE"
rm -rf "$STAGE"; mkdir -p "$STAGE"
# PoB2 application (the proven runtime/ + src/ sibling layout)
cp -r "$REPO_ROOT/runtime" "$STAGE/runtime"
cp -r "$REPO_ROOT/src"     "$STAGE/src"
cp "$REPO_ROOT/manifest.xml"  "$STAGE/manifest.xml"
cp "$REPO_ROOT/changelog.txt" "$STAGE/changelog.txt" 2>/dev/null || true
cp "$REPO_ROOT/help.txt"      "$STAGE/help.txt" 2>/dev/null || true
# The MCP server exe
cp "$BUILD/pob2-mcp.exe" "$STAGE/pob2-mcp.exe"
cp "$REPO_ROOT/scripts/dist-README.txt" "$STAGE/README.txt"

# MCP headless runner: config.ts resolves run_headless.lua at <POB_ROOT>/mcp-lua/
# in the shipped layout (the SEA exe's dir is the install folder, not a script dir,
# so the runner is anchored on POB_ROOT — see HEADLESS_RUNNER). Ship just that one
# script; it only needs the already-staged runtime/lua (dkjson) + src/ at run time.
mkdir -p "$STAGE/mcp-lua"
cp "$MCP/lua/run_headless.lua" "$STAGE/mcp-lua/run_headless.lua"

# The Windows headless interpreter (gui_optimize / search backend) rides along in
# the wholesale runtime/ copy above, paired with the identical runtime/lua51.dll
# and runtime/lua-utf8.dll (LuaJIT 2.1, same ABI). Assert it actually landed so the
# dist is honest about whether optimize/headless will work on the target.
if [[ -f "$STAGE/runtime/luajit.exe" ]]; then
  say "Headless backend: bundled runtime/luajit.exe ($("$STAGE/runtime/luajit.exe" -v 2>/dev/null | head -1 | tr -d '\r'))"
else
  printf '\n\033[33mWARNING: runtime/luajit.exe is missing — gui_optimize/headless search will be INERT in this dist.\n         Drop an ABI-matched LuaJIT 2.1 x64 luajit.exe into runtime/ and rebuild.\033[0m\n'
fi

# --- 5. zip it ----------------------------------------------------------------
# Set SKIP_ZIP=1 to leave just the staged folder (used by dev-update-local.sh,
# which syncs from the stage and doesn't need the multi-hundred-MB archive).
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
