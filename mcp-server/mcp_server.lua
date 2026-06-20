#!/usr/bin/env luajit
-- mcp_server.lua — the Path of Building 2 MCP server (Lua).
--
-- Replaces the old Node/TypeScript server. Launched by the MCP client over stdio
-- (see pob2-mcp/.mcp.json), it speaks MCP via the vendored `mcp-lua` library, forwards
-- the gui_* tools to the running PoB2 GUI over a TCP socket (src/Modules/MCPBridge.lua),
-- and runs compute/optimize headlessly by spawning luajit on run_headless.lua.
--
-- stdout carries the MCP protocol — diagnostics MUST go to stderr only.

-- 1. Locate ourselves so `require` works regardless of the launch cwd. An MCP client
--    launches us by (often absolute) path; arg[0] is that path.
local here = (arg and arg[0] or ""):gsub("[/\\][^/\\]*$", "")
if here == "" or here == (arg and arg[0]) then
	here = "."
end

-- 2. Put our own modules + the vendored mcp-lua on the path, then load config.
package.path = here .. "/lua/?.lua;"
	.. here .. "/vendor/mcp-lua/?.lua;"
	.. here .. "/vendor/mcp-lua/?/init.lua;"
	.. package.path

local config = require("config")

-- 3. Add PoB's bundled pure-Lua libs (dkjson, socket, sha1) + the LuaSocket core.
package.path = config.RUNTIME_LUA .. "/?.lua;" .. config.RUNTIME_LUA .. "/?/init.lua;" .. package.path
package.cpath = config.RUNTIME_DIR .. "/?." .. (config.isWindows and "dll" or "so") .. ";" .. package.cpath

local mcp = require("mcp")
local dkjson = require("dkjson")
local bridge = require("bridge")
local engine = require("engine")
local optimize = require("optimize")
local registerTools = require("tools.init")

local server = mcp.Server.new({ name = "pob2-mcp", version = "0.2.0" })
registerTools(server, {
	bridge = bridge,
	engine = engine,
	optimize = optimize,
	-- Raw dkjson (not mcp.json) so tool content can be pretty-printed with {indent=true};
	-- mcp.json is the protocol-layer encoder used internally by mcp-lua.
	json = dkjson,
})

io.stderr:write("pob2-mcp (lua) server running on stdio\n")
server:connect(mcp.StdioServerTransport.new())
