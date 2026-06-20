-- inproc.lua — in-process bridge adapter (replaces the old TCP bridge.lua).
--
-- When the MCP server runs INSIDE PoB, tool handlers call the MCPBridge `methods.*`
-- directly in the same Lua state — no socket. This adapter exposes the surface the
-- tool registry expects (`deps.bridge`): `call`/`raw` (sync) and `deferJob`/`callJob`
-- (async). Async tools don't block the frame: they start a job and return a
-- `{ __pending = poll }` sentinel; mcp-lua's Server:dispatch parks the HTTP connection
-- and the transport drives the poll once per OnFrame until the job resolves.
--
-- The `bridge` handle must expose `bridge:invoke(method, params) -> ok, result`
-- (a pcall over MCPBridge.methods[method](build, params)) and the job machinery
-- reachable via the `jobPoll` method.

local json = require("dkjson")

local M = {}

-- How long a parked async job may run before the adapter gives up (seconds).
local POLL_TIMEOUT = 120

local function resultContent(result)
	return { content = { { type = "text", text = json.encode(result, { indent = true }) } }, isError = false }
end

local function errorContent(message)
	return { content = { { type = "text", text = tostring(message) } }, isError = true }
end

M.resultContent = resultContent
M.errorContent = errorContent

-- Build an adapter bound to a Bridge handle (the MCPBridge module instance).
function M.new(bridge)
	local A = { errorContent = errorContent, resultContent = resultContent }

	-- Sync call → CallToolResult (never throws).
	function A.call(method, params)
		local ok, result = bridge:invoke(method, params)
		if ok then
			return resultContent(result)
		end
		return errorContent(result)
	end

	-- Sync call → raw result (throws on error). For composing handlers (optimize).
	function A.raw(method, params)
		local ok, result = bridge:invoke(method, params)
		if not ok then
			error(result, 0)
		end
		return result
	end

	-- Park on a job. `start` is either {jobId=N} (async, started elsewhere) or a plain
	-- result table (resolved synchronously). `finish(jobData) -> resultTable` post-
	-- processes the job's payload (default: identity); throwing in finish → error result.
	-- Returns a CallToolResult (sync case) or a { __pending = poll } sentinel.
	function A.deferJob(start, finish)
		finish = finish or function(d) return d end
		if type(start) ~= "table" or type(start.jobId) ~= "number" then
			local ok, r = pcall(finish, start)
			return ok and resultContent(r) or errorContent(r)
		end
		local jobId = start.jobId
		local deadline = os.time() + POLL_TIMEOUT
		return {
			__pending = function()
				local ok, job = bridge:invoke("jobPoll", { jobId = jobId })
				if not ok then
					return errorContent(job)
				end
				if job.status == "done" then
					local fok, r = pcall(finish, job.result)
					return fok and resultContent(r) or errorContent(r)
				elseif job.status == "error" then
					return errorContent(job.error or "job failed")
				end
				if os.time() > deadline then
					return errorContent("job timed out after " .. POLL_TIMEOUT .. "s")
				end
				return nil -- still running
			end,
		}
	end

	-- Async tool: invoke a start method that returns {jobId} (via MCPBridge.startJob),
	-- then defer on it. A synchronous result (no jobId) is returned as-is.
	function A.callJob(startMethod, params)
		local ok, start = bridge:invoke(startMethod, params)
		if not ok then
			return errorContent(start)
		end
		return A.deferJob(start)
	end

	return A
end

return M
