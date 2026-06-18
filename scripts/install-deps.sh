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
#   luarocks: luautf8 (the only compiled module PoB requires) and busted (tests)
#
# Everything else PoB needs (xml, sha1, socket, dkjson, base64) is bundled as
# pure Lua under runtime/lua/.
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

# --- 3. busted test runner (optional) -----------------------------------------
if [ "${SKIP_BUSTED:-0}" != "1" ]; then
	log "Installing busted test runner via luarocks"
	$SUDO "${ROCKS[@]}" install busted
else
	log "SKIP_BUSTED=1 — skipping busted"
fi

# --- 4. Node toolchain + MCP server (userland, no sudo) -----------------------
# The MCP server is Node/TypeScript and must run under LINUX Node (Windows Node
# cannot exec the Linux luajit headless binary). Install a userland Node LTS so
# this needs no root, then install + build the server under mcp/.
NODE_VER=v20.18.1
NODE_HOME="$HOME/.local/node/node-${NODE_VER}-linux-x64"
if [ "${SKIP_NODE:-0}" != "1" ]; then
	case "$(uname -m)" in
		x86_64) NA=x64;;
		aarch64) NA=arm64;;
		*) die "unsupported arch for userland Node: $(uname -m)";;
	esac
	NODE_HOME="$HOME/.local/node/node-${NODE_VER}-linux-${NA}"
	if [ ! -x "$NODE_HOME/bin/node" ]; then
		log "Installing userland Node $NODE_VER to $NODE_HOME"
		mkdir -p "$HOME/.local/node"
		curl -fsSL --max-time 180 \
			"https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-${NA}.tar.xz" \
			-o /tmp/node.tar.xz
		tar -xJf /tmp/node.tar.xz -C "$HOME/.local/node"
	fi
	export PATH="$NODE_HOME/bin:$PATH"
	log "Node $(node --version) / npm $(npm --version)"

	log "Installing + building the MCP server (mcp/)"
	( cd "$REPO_ROOT/mcp" && npm install && npm run build )

	warn "Add Node to your PATH for future shells:"
	warn "  export PATH=\"$NODE_HOME/bin:\$PATH\""
else
	log "SKIP_NODE=1 — skipping Node / MCP server"
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
  • Launch the Windows GUI (via WSL interop):
      "runtime/Path{space}of{space}Building-PoE2.exe"
EOF
