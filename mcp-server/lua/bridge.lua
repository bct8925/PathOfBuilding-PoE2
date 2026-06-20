-- bridge.lua — client for the in-app Lua socket bridge (src/Modules/MCPBridge.lua)
-- running inside a live PoB2 GUI.
--
-- Lua port of bridge/socket.ts + the callBridge/callBridgeJob/rawBridge/rawBridgeJob
-- helpers from index.ts. Protocol: newline-delimited JSON over TCP. Each request is
-- {id,method,params}; each response {id,ok,result|error}. The MCP server serves one
-- tool call at a time, so a simple BLOCKING request→response is enough (no async).
--
-- Four entry points, mirroring the TS:
--   raw(method, params)            -> result        (throws on transport/handler error)
--   rawJob(startMethod, params, o) -> result        (start a job, poll jobPoll, throws)
--   call(method, params)           -> CallToolResult (never throws; friendly error text)
--   callJob(startMethod, params,o) -> CallToolResult (never throws)

local socket = require("socket")
local json = require("dkjson")
local config = require("config")

local M = {}

local CONNECT_TIMEOUT = 5 -- seconds
local REQUEST_TIMEOUT = 15 -- seconds (a recalc-heavy mutation can take a moment)

-- Open a short-lived connection to the bridge. Returns a conn table or (nil, err).
local function connect()
	local sock, err = socket.tcp()
	if not sock then
		return nil, "could not create socket: " .. tostring(err)
	end
	sock:settimeout(CONNECT_TIMEOUT)
	local ok, cerr = sock:connect(config.BRIDGE_HOST, config.BRIDGE_PORT)
	if not ok then
		sock:close()
		return nil,
			("could not reach PoB GUI bridge at %s:%d (%s) — is PoB running with the bridge loaded?")
				:format(config.BRIDGE_HOST, config.BRIDGE_PORT, tostring(cerr))
	end
	sock:settimeout(REQUEST_TIMEOUT)
	return { sock = sock, nextId = 1 }
end

-- Send one request and read its response line. Returns the decoded response table
-- ({id,ok,result|error}) or (nil, err) on a transport failure.
local function send(conn, method, params)
	local id = conn.nextId
	conn.nextId = id + 1
	local payload = json.encode({ id = id, method = method, params = params or {} }) .. "\n"
	local ok, serr = conn.sock:send(payload)
	if not ok then
		return nil, "bridge send failed: " .. tostring(serr)
	end
	local line, rerr = conn.sock:receive("*l")
	if not line then
		return nil, "bridge receive failed: " .. tostring(rerr)
	end
	local decoded, _, derr = json.decode(line)
	if derr or type(decoded) ~= "table" then
		return nil, "bridge returned malformed JSON: " .. tostring(derr)
	end
	return decoded
end

local function close(conn)
	if conn and conn.sock then
		pcall(function() conn.sock:close() end)
	end
end

-- raw(method, params) -> result. Throws (via error()) on transport or handler error,
-- so composing callers (optimize) can pcall around several calls.
function M.raw(method, params)
	local conn, cerr = connect()
	if not conn then
		error(cerr, 0)
	end
	local resp, serr = send(conn, method, params)
	close(conn)
	if not resp then
		error(serr, 0)
	end
	if not resp.ok then
		error(resp.error or ("bridge method '" .. method .. "' failed"), 0)
	end
	return resp.result
end

-- rawJob: start an async job, then poll jobPoll on the SAME connection until it
-- resolves. A non-job (synchronous) result is returned as-is. Throws on error.
function M.rawJob(startMethod, params, opts)
	opts = opts or {}
	local pollSeconds = (opts.pollMs or 250) / 1000
	local timeoutSeconds = (opts.timeoutMs or 60000) / 1000

	local conn, cerr = connect()
	if not conn then
		error(cerr, 0)
	end

	local resp, serr = send(conn, startMethod, params)
	if not resp then
		close(conn)
		error(serr, 0)
	end
	if not resp.ok then
		close(conn)
		error(resp.error or ("bridge method '" .. startMethod .. "' failed"), 0)
	end
	local start = resp.result
	if type(start) ~= "table" or type(start.jobId) ~= "number" then
		close(conn) -- resolved synchronously
		return start
	end

	local deadline = os.time() + math.ceil(timeoutSeconds)
	while true do
		local pollResp, perr = send(conn, "jobPoll", { jobId = start.jobId })
		if not pollResp then
			close(conn)
			error(perr, 0)
		end
		if not pollResp.ok then
			close(conn)
			error(pollResp.error or "jobPoll failed", 0)
		end
		local job = pollResp.result
		if job.status == "done" then
			close(conn)
			return job.result
		elseif job.status == "error" then
			close(conn)
			error(job.error or "job failed", 0)
		end
		if os.time() > deadline then
			close(conn)
			error(("bridge job '%s' did not finish within %dms"):format(startMethod, opts.timeoutMs or 60000), 0)
		end
		socket.sleep(pollSeconds)
	end
end

-- Format a result table as the MCP CallToolResult content text (pretty JSON).
local function resultContent(result)
	return {
		content = { { type = "text", text = json.encode(result, { indent = true }) } },
		isError = false,
	}
end

local function errorContent(message)
	return {
		content = {
			{
				type = "text",
				text = "GUI bridge error: "
					.. tostring(message)
					.. '\nIs PoB2 running with the "Enable MCP bridge" Option turned on (Options menu)?',
			},
		},
		isError = true,
	}
end

-- call / callJob: the tool-facing wrappers. Never throw — return a CallToolResult.
function M.call(method, params)
	local ok, result = pcall(M.raw, method, params)
	if ok then
		return resultContent(result)
	end
	return errorContent(result)
end

function M.callJob(startMethod, params, opts)
	local ok, result = pcall(M.rawJob, startMethod, params, opts)
	if ok then
		return resultContent(result)
	end
	return errorContent(result)
end

return M
