-- config.lua — path/runtime resolution for the Lua MCP server.
--
-- Lua port of the old config.ts. Works in BOTH layouts without baking in WSL/dev
-- assumptions (NFR-1):
--   - dev:     this file is <repo>/mcp-server/lua/config.lua → POB_ROOT is <repo>
--   - shipped: the same tree sits in PoB's folder              → POB_ROOT is that folder
-- An explicit POB_ROOT env var overrides the search (the .mcp.json passes it).

local M = {}

-- Windows if the path separator config starts with a backslash.
M.isWindows = package.config:sub(1, 1) == "\\"

local function exists(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	return false
end
M.exists = exists

-- Strip the last path segment. Accepts / or \ separators.
local function dirname(path)
	return (path:gsub("[/\\][^/\\]*$", ""))
end

-- This file's own directory (mcp-server/lua), via the debug source path.
local function thisDir()
	local src = debug.getinfo(1, "S").source
	if src:sub(1, 1) == "@" then
		src = src:sub(2)
	end
	local dir = dirname(src)
	if dir == "" or dir == src then
		dir = "."
	end
	return dir
end

-- Resolve POB_ROOT: explicit env wins; else walk up from here looking for the
-- distribution marker (src/HeadlessWrapper.lua); else fall back to mcp-server/.. .
local function findPobRoot()
	local env = os.getenv("POB_ROOT")
	if env and env ~= "" then
		return (env:gsub("[/\\]$", ""))
	end
	local dir = thisDir()
	for _ = 1, 8 do
		if exists(dir .. "/src/HeadlessWrapper.lua") then
			return dir
		end
		local parent = dirname(dir)
		if parent == dir or parent == "" then
			break
		end
		dir = parent
	end
	-- Fallback: mcp-server/lua → up two = repo root.
	return dirname(dirname(thisDir()))
end

M.POB_ROOT = findPobRoot()
M.SRC_DIR = M.POB_ROOT .. "/src"
M.RUNTIME_DIR = M.POB_ROOT .. "/runtime"
M.RUNTIME_LUA = M.RUNTIME_DIR .. "/lua"
M.MCP_SERVER_DIR = M.POB_ROOT .. "/mcp-server"

-- LUA_PATH the headless engine expects (matches scripts/install-deps.sh).
M.LUA_PATH = M.RUNTIME_LUA .. "/?.lua;" .. M.RUNTIME_LUA .. "/?/init.lua;;"

-- LUA_CPATH for the headless engine: platform default first (dev luarocks .so), then
-- the bundled runtime dir with the platform-correct extension (shipped Windows .dll).
M.LUA_CPATH = ";;" .. M.RUNTIME_DIR .. "/?." .. (M.isWindows and "dll" or "so")

-- luajit binary for the headless/search child: POB_LUAJIT override → bundled
-- runtime/luajit.exe on Windows → 'luajit' on PATH (Linux dev).
local function resolveLuajit()
	local env = os.getenv("POB_LUAJIT")
	if env and env ~= "" then
		return env
	end
	if M.isWindows then
		local bundled = M.RUNTIME_DIR .. "/luajit.exe"
		if exists(bundled) then
			return bundled
		end
	end
	return "luajit"
end
M.LUAJIT = resolveLuajit()

-- The headless runner that boots HeadlessWrapper and emits JSON. POB_HEADLESS_RUNNER
-- overrides; otherwise it lives beside this file under mcp-server/lua/.
local function resolveHeadlessRunner()
	local env = os.getenv("POB_HEADLESS_RUNNER")
	if env and env ~= "" then
		return env
	end
	return M.MCP_SERVER_DIR .. "/lua/run_headless.lua"
end
M.HEADLESS_RUNNER = resolveHeadlessRunner()

-- Live-GUI socket bridge connection (MCPBridge.lua listens here).
M.BRIDGE_HOST = os.getenv("POB_BRIDGE_HOST") or "127.0.0.1"
M.BRIDGE_PORT = tonumber(os.getenv("POB_BRIDGE_PORT")) or 8843

return M
