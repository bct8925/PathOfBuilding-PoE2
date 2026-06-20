#!/usr/bin/env bash
#
# install-deps.sh — Install dependencies for running Path of Building 2 headless
# (the Lua calc engine) and its test suite on a Debian/Ubuntu host or WSL.
#
# The Windows GUI (runtime/*.exe) is launched directly via WSL interop and needs
# no Linux-side dependencies. This script provisions only the Lua toolchain used
# by the headless engine that the MCP server drives, plus the busted test runner.
#
# What it installs:
#   apt:      build-essential luajit lua5.1 liblua5.1-dev luarocks git curl unzip
#   luarocks: luautf8 (the compiled module PoB's calc engine requires),
#             luasocket (the MCP server's bridge client needs the LuaSocket C core;
#             Windows ships runtime/socket.dll, Linux dev needs this), busted (tests)
#
# The rest PoB needs (xml, sha1, dkjson, base64, the socket Lua wrapper) is bundled
# as pure Lua under runtime/lua/. The MCP server itself is plain Lua (no Node).
#
# Usage:
#   scripts/install-deps.sh            # install everything (apt + luarocks)
#   SKIP_BUSTED=1 scripts/install-deps.sh   # skip the test runner
#   SKIP_APT=1   scripts/install-deps.sh    # only run luarocks steps
#
set -euo pipefail

# --- locate repo root (this script lives in <root>/scripts) -------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- helpers ------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Choose a sudo prefix only if we are not already root.
if [ "$(id -u)" -eq 0 ]; then
	SUDO=""
else
	command -v sudo >/dev/null 2>&1 || die "need root or sudo to install apt packages"
	SUDO="sudo"
fi

LUA_VERSION=5.1   # PoB targets the Lua 5.1 ABI (LuaJIT is 5.1-compatible)

# --- 1. system packages -------------------------------------------------------
APT_PKGS=(build-essential luajit lua5.1 liblua5.1-dev luarocks git curl unzip)

if [ "${SKIP_APT:-0}" != "1" ]; then
	command -v apt-get >/dev/null 2>&1 || die "apt-get not found; this script targets Debian/Ubuntu/WSL"
	log "Installing system packages: ${APT_PKGS[*]}"
	$SUDO apt-get update
	$SUDO apt-get install -y "${APT_PKGS[@]}"
else
	log "SKIP_APT=1 — skipping apt step"
fi

command -v luarocks >/dev/null 2>&1 || die "luarocks not on PATH after install"
command -v luajit   >/dev/null 2>&1 || die "luajit not on PATH after install"

# luarocks needs --lua-version when several Lua dev headers are present; pin 5.1.
ROCKS=("luarocks" "--lua-version=$LUA_VERSION")
if ! "${ROCKS[@]}" config lua_version >/dev/null 2>&1; then
	# Older luarocks without --lua-version support: fall back to the bare command.
	ROCKS=("luarocks")
fi

# --- 2. luautf8 (required compiled module) ------------------------------------
log "Installing luautf8 via luarocks (Lua $LUA_VERSION)"
$SUDO "${ROCKS[@]}" install luautf8

# --- 3. luasocket (MCP server bridge client) ----------------------------------
# The Lua MCP server connects to the running PoB2 GUI over TCP via LuaSocket. The
# bundled runtime/lua/socket.lua is a pure-Lua wrapper over a compiled core; on
# Windows that's runtime/socket.dll, but Linux dev needs the C core installed.
log "Installing luasocket via luarocks"
$SUDO "${ROCKS[@]}" install luasocket

# --- 4. busted test runner (optional) -----------------------------------------
if [ "${SKIP_BUSTED:-0}" != "1" ]; then
	log "Installing busted test runner via luarocks"
	$SUDO "${ROCKS[@]}" install busted
else
	log "SKIP_BUSTED=1 — skipping busted"
fi

# --- 5. verify the headless engine boots --------------------------------------
log "Verifying luautf8 loads under luajit"
luajit -e "require('lua-utf8'); print('luautf8 OK')" \
	|| die "luajit cannot load lua-utf8 — check luarocks install tree / package.cpath"

log "Booting the headless calc engine (HeadlessWrapper.lua)"
(
	cd "$REPO_ROOT/src"
	# runtime/lua holds the bundled pure-Lua libs (xml, sha1, socket, ...).
	# CI=true prevents loading the large generated ModCache during boot.
	LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;" CI=true \
		luajit HeadlessWrapper.lua
) && log "Headless engine booted successfully." \
  || die "HeadlessWrapper.lua failed to boot — see output above"

cat <<EOF

All dependencies installed.

Next steps:
  • Run the headless engine:
      cd src && LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;" luajit HeadlessWrapper.lua
  • Run the test suite (from the repo root, where .busted lives):
      busted --lua=luajit
  • Run the MCP server tests (wiring + headless e2e + MCPBridge regression):
      mcp-server/run_tests.sh
  • Launch the Windows GUI (via WSL interop):
      "runtime/Path{space}of{space}Building-PoE2.exe"
EOF
