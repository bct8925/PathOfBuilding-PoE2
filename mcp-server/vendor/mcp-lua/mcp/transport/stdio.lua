-- mcp.transport.stdio — newline-delimited JSON over stdin/stdout.
--
-- The MCP stdio wire format: each JSON-RPC message is a single line of JSON ending
-- in "\n" (no Content-Length headers). This is safe to read with a *blocking* line
-- loop because the server runs as a process the client spawns and owns — unlike an
-- in-GUI bridge, it can block on stdin between messages.
--
-- Transport contract (so other transports — e.g. a TCP socket to a running app —
-- can drop in): :start(onMessage), :send(messageTable), :close().
--   - onMessage receives a *decoded* message table; the transport owns framing+parse.
--   - On a malformed line the transport replies with a JSON-RPC PARSE_ERROR itself.
--
-- IMPORTANT: stdout carries the protocol — never print anything else to it. Diagnostics
-- go to stderr.

local json = require("mcp.json")
local jsonrpc = require("mcp.jsonrpc")

local Stdio = {}
Stdio.__index = Stdio

function Stdio.new(opts)
	opts = opts or {}
	return setmetatable({
		input = opts.input or io.stdin,
		output = opts.output or io.stdout,
		running = false,
	}, Stdio)
end

-- Write a message table as one JSON line, flushing so the client sees it immediately.
function Stdio:send(message)
	self.output:write(json.encode(message) .. "\n")
	self.output:flush()
end

-- Read messages until EOF (stdin closed). Decodes each line; hands decoded messages to
-- onMessage; answers malformed lines with a PARSE_ERROR directly.
function Stdio:start(onMessage)
	self.running = true
	for line in self.input:lines() do
		if not self.running then
			break
		end
		-- Tolerate CRLF and stray blank lines.
		line = line:gsub("\r$", "")
		if line:match("%S") then
			local msg, err = json.decode(line)
			if err or msg == nil then
				self:send(jsonrpc.error(nil, jsonrpc.errors.PARSE_ERROR, "parse error: " .. tostring(err)))
			else
				onMessage(msg)
			end
		end
	end
	self.running = false
end

function Stdio:close()
	self.running = false
end

return Stdio
