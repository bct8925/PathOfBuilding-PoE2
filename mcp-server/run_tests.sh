#!/usr/bin/env bash
# Run the Lua MCP server test suite. Override the interpreter with LUA_BIN (default luajit).
#
#   ./run_tests.sh                # luajit
#   LUA_BIN=lua5.1 ./run_tests.sh
#
# Covers: server wiring (test_server); the in-PoB HTTP MCP transport end-to-end
# (test_http); and the MCPBridge.lua regression suite (test_bridge). test_http and
# test_bridge run from src/ so HeadlessWrapper + MCPBridge boot.
set -uo pipefail
cd "$(dirname "$0")"
LUA_BIN="${LUA_BIN:-luajit}"
export LUA_BIN
fail=0

echo "===== test_server ($LUA_BIN) ====="
"$LUA_BIN" test/test_server.lua || fail=1

run_in_src() { # <label> <test-file>
	( cd ../src && LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;" CI=true \
		"$LUA_BIN" "../mcp-server/$2" >"/tmp/pob2_$1.log" 2>&1 )
	if grep -qE "ALL PASS|0 failed" "/tmp/pob2_$1.log"; then
		echo "  $1: PASS"
	else
		echo "  $1: FAILED (see /tmp/pob2_$1.log)"; tail -20 "/tmp/pob2_$1.log"; fail=1
	fi
}

echo "===== test_http — in-PoB HTTP transport ($LUA_BIN) ====="
run_in_src test_http test/test_http.lua

echo "===== test_bridge — MCPBridge.lua regression ($LUA_BIN) ====="
run_in_src test_bridge test/test_bridge.lua

exit "$fail"
