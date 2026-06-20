-- engine.lua — headless calc/search backend.
--
-- Lua port of engine/headless.ts. The TS used child_process.spawn with cwd + env;
-- here we compose a platform-branched shell command and run it via io.popen, feeding
-- the JSON request on stdin via a temp file (io.popen is unidirectional, so we can't
-- both write the child's stdin and read its stdout on one handle). The runner
-- (run_headless.lua) is UNCHANGED: it boots HeadlessWrapper (which needs cwd=src) and
-- prints one result line prefixed with the sentinel.

local json = require("dkjson")
local config = require("config")

local M = {}

local RESULT_PREFIX = "@@POB_RESULT@@"
local tmpCounter = 0

-- A writable temp-file path (own counter keeps it unique within this process).
local function tempPath()
	tmpCounter = tmpCounter + 1
	local dir = os.getenv("TMPDIR") or os.getenv("TMP") or os.getenv("TEMP") or (config.isWindows and "." or "/tmp")
	return ("%s/pob2_mcp_%d_%d.json"):format((dir:gsub("[/\\]$", "")), os.time(), tmpCounter)
end

-- Shell-quote a single argument for the platform shell.
local function q(s)
	if config.isWindows then
		return '"' .. tostring(s) .. '"'
	end
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Build the command that cd's to src/, sets the engine env, and runs the runner with
-- the request file redirected to stdin.
local function buildCommand(reqFile)
	local L, RUNNER, SRC, LUAJIT = config.LUA_PATH, config.HEADLESS_RUNNER, config.SRC_DIR, config.LUAJIT
	if config.isWindows then
		return table.concat({
			"cd /d " .. q(SRC),
			'set "LUA_PATH=' .. L .. '"',
			'set "LUA_CPATH=' .. config.LUA_CPATH .. '"',
			'set "CI=true"',
			q(LUAJIT) .. " " .. q(RUNNER) .. " < " .. q(reqFile),
		}, " && ")
	end
	return ("cd %s && LUA_PATH=%s LUA_CPATH=%s CI=true %s %s < %s"):format(
		q(SRC), q(L), q(config.LUA_CPATH), q(LUAJIT), q(RUNNER), q(reqFile)
	)
end

-- Run one headless job: write the request, spawn the runner, parse the sentinel line.
-- Returns the decoded result table, or { ok=false, error=... } on failure.
local function run(request)
	local reqFile = tempPath()
	local fh, ferr = io.open(reqFile, "w")
	if not fh then
		return { ok = false, error = "could not write temp request file: " .. tostring(ferr) }
	end
	fh:write(json.encode(request))
	fh:close()

	local proc, perr = io.popen(buildCommand(reqFile), "r")
	if not proc then
		os.remove(reqFile)
		return { ok = false, error = "could not spawn headless engine: " .. tostring(perr) }
	end
	local out = proc:read("*a") or ""
	proc:close()
	os.remove(reqFile)

	for line in (out .. "\n"):gmatch("(.-)\r?\n") do
		if line:sub(1, #RESULT_PREFIX) == RESULT_PREFIX then
			local decoded, _, derr = json.decode(line:sub(#RESULT_PREFIX + 1))
			if derr then
				return { ok = false, error = "failed to parse headless result JSON: " .. tostring(derr) }
			end
			return decoded
		end
	end
	return {
		ok = false,
		error = "no result from headless engine.\noutput tail:\n" .. out:sub(-2000),
	}
end

-- compute: stateless single build calc (mirrors computeHeadless).
function M.compute(request)
	request = request or {}
	request.action = "compute"
	return run(request)
end

-- search: evaluate candidate change-sets off a snapshot (mirrors searchHeadless).
function M.search(request)
	request = request or {}
	request.action = "search"
	return run(request)
end

return M
