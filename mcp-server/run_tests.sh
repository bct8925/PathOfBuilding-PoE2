#!/usr/bin/env bash
# Run the Lua MCP server test suite. Override the interpreter with LUA_BIN (default luajit).
#
#   ./run_tests.sh                # luajit
#   LUA_BIN=lua5.1 ./run_tests.sh
#
# Covers: server wiring (test_server), end-to-end MCP over stdio incl. headless calc
# (integration_headless), and the MCPBridge.lua regression suite (test_bridge, run from
# src/ so HeadlessWrapper boots).
set -uo pipefail
cd "$(dirname "$0")"
LUA_BIN="${LUA_BIN:-luajit}"
export LUA_BIN
fail=0

echo "===== test_server ($LUA_BIN) ====="
"$LUA_BIN" test/test_server.lua || fail=1

echo "===== integration_headless ($LUA_BIN) ====="
"$LUA_BIN" test/integration_headless.lua || fail=1

echo "===== test_bridge — MCPBridge.lua regression ($LUA_BIN) ====="
( cd ../src && LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;" CI=true \
	"$LUA_BIN" ../mcp-server/test/test_bridge.lua >/tmp/pob2_test_bridge.log 2>&1 )
if grep -q "ALL PASS" /tmp/pob2_test_bridge.log; then
	echo "  test_bridge: ALL PASS"
else
	echo "  test_bridge: FAILED (see /tmp/pob2_test_bridge.log)"; tail -20 /tmp/pob2_test_bridge.log; fail=1
fi

exit "$fail"
