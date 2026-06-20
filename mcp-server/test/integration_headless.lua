-- test/integration_headless.lua — end-to-end MCP over real stdio, no GUI.
-- Spawns `luajit mcp_server.lua`, feeds it a full MCP session (initialize → initialized
-- → tools/list → tools/call compute_build_stats), and asserts the newline-JSON responses.
-- compute_build_stats spawns the headless engine, so this exercises the whole stack
-- except the live bridge. Set LUA_BIN to run the server under a specific interpreter.

local here = (arg[0] or ""):gsub("[/\\][^/\\]*$", "")
if here == "" then here = "." end
local root = here .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/vendor/mcp-lua/?.lua;" .. root .. "/vendor/mcp-lua/?/init.lua;" .. package.path
local config = require("config")
package.path = config.RUNTIME_LUA .. "/?.lua;" .. config.RUNTIME_LUA .. "/?/init.lua;" .. package.path
local json = require("dkjson")

local LUA_BIN = os.getenv("LUA_BIN") or "luajit"
local SERVER = config.MCP_SERVER_DIR .. "/mcp_server.lua"

local passed, failed = 0, 0
local function check(c, m)
	if c then passed = passed + 1; print("  ok - " .. m) else failed = failed + 1; print("  NOT OK - " .. m) end
end

local session = {
	{ jsonrpc = "2.0", id = 1, method = "initialize", params = { protocolVersion = "2025-06-18", capabilities = {} } },
	{ jsonrpc = "2.0", method = "notifications/initialized" },
	{ jsonrpc = "2.0", id = 2, method = "tools/list", params = {} },
	{ jsonrpc = "2.0", id = 3, method = "tools/call", params = { name = "compute_build_stats", arguments = { stats = { "Life", "TotalDPS" } } } },
}

-- Write the session to a temp file and redirect it into the server's stdin.
local infile = os.tmpname()
local fh = assert(io.open(infile, "w"))
for _, m in ipairs(session) do fh:write(json.encode(m) .. "\n") end
fh:close()

local cmd = ("POB_ROOT=%q %q %q < %q 2>/dev/null"):format(config.POB_ROOT, LUA_BIN, SERVER, infile)
local proc = assert(io.popen(cmd, "r"))
local byId = {}
for line in proc:lines() do
	if line:match("%S") then
		local d = json.decode(line)
		if d and d.id then byId[d.id] = d end
	end
end
proc:close()
os.remove(infile)

print("# initialize")
check(byId[1] and byId[1].result and byId[1].result.serverInfo.name == "pob2-mcp", "serverInfo.name is pob2-mcp")

print("# tools/list")
check(byId[2] and byId[2].result and #byId[2].result.tools == 45, "advertises 45 tools")

print("# tools/call compute_build_stats")
local call = byId[3]
check(call and call.result, "compute_build_stats responded")
if call and call.result then
	check(not call.result.isError, "not an error result")
	local text = call.result.content[1].text
	local parsed = json.decode(text)
	check(parsed and parsed.ok == true, "headless calc reported ok")
	check(parsed and parsed.stats and type(parsed.stats.Life) == "number", "returned a numeric Life stat")
end

print(("\nintegration_headless: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
