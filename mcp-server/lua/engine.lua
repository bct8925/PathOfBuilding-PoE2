-- engine.lua — headless calc/search backend, run OFF the GUI frame via LaunchSubScript.
--
-- When the MCP server is hosted inside PoB, a blocking `io.popen` on the main thread
-- would freeze OnFrame. Instead we use PoB's native background mechanism: LaunchSubScript
-- runs a tiny `io.popen` wrapper on its OWN thread (so the GUI stays responsive) that
-- executes the UNCHANGED run_headless.lua child; the result returns via the subscript
-- callback (OnSubFinished) and resolves a Bridge job. All JSON/file/parse stays on the
-- main thread, so the subscript only needs `io.popen`.
--
-- `M.new(bridge)` binds to the Bridge (uses bridge.startJob + Bridge.jobs). The headless
-- engine itself still runs under the bundled runtime/luajit.exe (config.LUAJIT).

local json = require("dkjson")
local config = require("config")

local M = {}

local RESULT_PREFIX = "@@POB_RESULT@@"

-- Subscript body: receives the prebuilt shell command, runs it on a background thread,
-- returns the child's full stdout. Only needs io.popen (no json/require), so it works in
-- the restricted subscript environment.
local POPEN_SUBSCRIPT = [[
	local cmd = ...
	local p = io.popen(cmd, "r")
	local out = p and p:read("*a") or ""
	if p then p:close() end
	return out
]]

local tmpCounter = 0
local function tempPath()
	tmpCounter = tmpCounter + 1
	local dir = os.getenv("TMPDIR") or os.getenv("TMP") or os.getenv("TEMP") or (config.isWindows and "." or "/tmp")
	return ("%s/pob2_mcp_%d_%d.json"):format((dir:gsub("[/\\]$", "")), os.time(), tmpCounter)
end

local function q(s)
	if config.isWindows then
		return '"' .. tostring(s) .. '"'
	end
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Compose the command that cd's to src/, sets the engine env, and runs the runner with
-- the request file on stdin. Reused verbatim from the old (process-spawning) engine.
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

local function extractResult(out)
	for line in (tostring(out) .. "\n"):gmatch("(.-)\r?\n") do
		if line:sub(1, #RESULT_PREFIX) == RESULT_PREFIX then
			return line:sub(#RESULT_PREFIX + 1)
		end
	end
	return nil
end

function M.new(bridge)
	local E = {}

	-- Start a headless job. Returns { jobId, status } (or {status="error"} if the
	-- background mechanism is unavailable). The job resolves with the decoded result
	-- table the runner emitted.
	local function startHeadless(req)
		local reqFile = tempPath()
		local fh, ferr = io.open(reqFile, "w")
		if not fh then
			return bridge.startJob(function(_, reject) reject("could not write temp request: " .. tostring(ferr)) end)
		end
		fh:write(json.encode(req))
		fh:close()
		local command = buildCommand(reqFile)

		return bridge.startJob(function(resolve, reject)
			-- LaunchSubScript is a PoB global; absent under plain luajit (tests).
			if type(LaunchSubScript) ~= "function" then
				os.remove(reqFile)
				reject("headless background search needs the PoB GUI (LaunchSubScript unavailable)")
				return
			end
			local id = LaunchSubScript(POPEN_SUBSCRIPT, "", "ConPrintf", command)
			if not id then
				os.remove(reqFile)
				reject("LaunchSubScript returned nil (could not start background search)")
				return
			end
			launch:RegisterSubScript(id, function(out, errMsg)
				os.remove(reqFile)
				if not out then
					reject(errMsg or "headless subscript failed")
					return
				end
				local line = extractResult(out)
				if not line then
					reject("no result from headless engine\n" .. tostring(out):sub(-1000))
					return
				end
				local decoded, _, derr = json.decode(line)
				if derr then
					reject("failed to parse headless result JSON: " .. tostring(derr))
					return
				end
				resolve(decoded)
			end)
		end)
	end

	-- compute: stateless single-build calc. Returns a job start ({jobId}).
	function E.startCompute(req)
		req = req or {}
		req.action = "compute"
		return startHeadless(req)
	end

	-- search: evaluate candidate change-sets off a snapshot. Returns a job start ({jobId}).
	function E.startSearch(req)
		req = req or {}
		req.action = "search"
		return startHeadless(req)
	end

	return E
end

return M
