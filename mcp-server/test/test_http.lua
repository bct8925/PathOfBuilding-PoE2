-- test/test_http.lua — exercise the in-PoB HTTP MCP transport end to end, headless.
--
-- Boots the engine, loads MCPBridge, builds the in-process MCP server, and drives
-- Bridge:serviceClient with a FAKE non-blocking socket feeding raw HTTP requests —
-- asserting well-formed HTTP + JSON-RPC responses for initialize / tools/list /
-- notification / a sync tools/call, the deferred (parked) path, and GET/parse errors.
--
-- Run from src/ (HeadlessWrapper + MCPBridge need cwd=src), e.g.:
--   cd src && LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;" CI=true \
--     luajit ../mcp-server/test/test_http.lua

dofile("HeadlessWrapper.lua")
newBuild()
runCallback("OnFrame")

local json = require("dkjson")
local Bridge = LoadModule("Modules/MCPBridge")
Bridge.build = build
Bridge.mcpServer = Bridge:buildMcpServer()

local passed, failed = 0, 0
local function check(c, m)
	if c then passed = passed + 1; print("  ok - " .. m) else failed = failed + 1; print("  NOT OK - " .. m) end
end

-- A fake non-blocking socket that yields one request in chunks and records sends.
local function fakeSock(req)
	local pos, sent = 1, {}
	return {
		_sent = sent,
		receive = function(_, n)
			if pos > #req then return nil, "timeout", "" end
			local c = req:sub(pos, pos + n - 1)
			pos = pos + #c
			return nil, "timeout", c
		end,
		send = function(_, d) sent[#sent + 1] = d; return #d end,
		close = function() end,
		settimeout = function() end,
	}
end

local function post(bodyTbl)
	local b = type(bodyTbl) == "string" and bodyTbl or json.encode(bodyTbl)
	return ("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"):format(#b, b)
end

-- Drive a raw request to completion; return (status, decodedBody|nil, rawBody).
local function roundtrip(rawRequest)
	local c = { sock = fakeSock(rawRequest), buf = "" }
	local done, guard = false, 0
	while not done and guard < 50 do
		done = Bridge:serviceClient(c)
		guard = guard + 1
	end
	local raw = table.concat(c.sock._sent)
	local status = raw:match("^HTTP/1.1 ([^\r]+)")
	local body = raw:match("\r\n\r\n(.*)$") or ""
	local decoded = #body > 0 and json.decode(body) or nil
	return status, decoded, body
end

print("# initialize")
do
	local status, resp = roundtrip(post({ jsonrpc = "2.0", id = 1, method = "initialize", params = { protocolVersion = "2025-06-18", capabilities = {} } }))
	check(status == "200 OK", "200 OK")
	check(resp and resp.result and resp.result.serverInfo.name == "pob2-mcp", "serverInfo.name is pob2-mcp")
	check(resp and resp.result.protocolVersion == "2025-06-18", "negotiated protocol version")
	check(resp and resp.result.capabilities.tools ~= nil, "advertises tools capability")
end

print("# tools/list")
do
	local status, resp = roundtrip(post({ jsonrpc = "2.0", id = 2, method = "tools/list" }))
	check(status == "200 OK", "200 OK")
	check(resp and #resp.result.tools == 45, "advertises 45 tools")
end

print("# notification → 202, no body")
do
	local status, _, body = roundtrip(post({ jsonrpc = "2.0", method = "notifications/initialized" }))
	check(status == "202 Accepted", "202 Accepted")
	check(body == "", "empty body")
end

print("# sync tools/call (gui_get_build on the headless build)")
do
	local status, resp = roundtrip(post({ jsonrpc = "2.0", id = 3, method = "tools/call", params = { name = "gui_get_build", arguments = {} } }))
	check(status == "200 OK", "200 OK")
	check(resp and resp.result and resp.result.content and resp.result.content[1].type == "text", "returns a text content block")
	local payload = resp and resp.result and json.decode(resp.result.content[1].text)
	check(payload and payload.className ~= nil, "build identity present (className)")
end

print("# deferred path parks then resolves (compute_build_stats; subscript unavailable headless → isError)")
do
	local status, resp = roundtrip(post({ jsonrpc = "2.0", id = 4, method = "tools/call", params = { name = "compute_build_stats", arguments = {} } }))
	check(status == "200 OK", "200 OK after parking + poll")
	check(resp and resp.result and resp.result.isError == true, "headless-unavailable surfaces as an isError result (deferred path works)")
end

print("# unknown tool → JSON-RPC error")
do
	local _, resp = roundtrip(post({ jsonrpc = "2.0", id = 5, method = "tools/call", params = { name = "nope", arguments = {} } }))
	check(resp and resp.error and resp.error.code == -32602, "INVALID_PARAMS for unknown tool")
end

print("# GET → 405")
do
	local c = { sock = fakeSock("GET /mcp HTTP/1.1\r\nHost: x\r\n\r\n"), buf = "" }
	local done, guard = false, 0
	while not done and guard < 10 do done = Bridge:serviceClient(c); guard = guard + 1 end
	local status = table.concat(c.sock._sent):match("^HTTP/1.1 ([^\r]+)")
	check(status == "405 Method Not Allowed", "405 on GET (no SSE channel)")
end

print("# malformed JSON → parse error")
do
	local _, resp = roundtrip(post("{not json"))
	check(resp and resp.error and resp.error.code == -32700, "PARSE_ERROR on bad JSON")
end

print(("\ntest_http: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
