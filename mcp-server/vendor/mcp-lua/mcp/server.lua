-- mcp.server — the MCP server, mirroring the JS SDK's `McpServer`.
--
-- Usage parity with @modelcontextprotocol/sdk:
--   local server = Server.new({ name = "echo", version = "0.1.0" })
--   server:tool(name, description, inputSchema, function(args, extra) ... end)
--   server:connect(transport)   -- blocks, serving the protocol
--
-- It handles the tools-first method surface: initialize, notifications/initialized,
-- ping, tools/list, tools/call. The routing core, `_handleMessage`, is pure (message
-- table in, response table or nil out) so it can be unit-tested without any transport.

local json = require("mcp.json")
local jsonrpc = require("mcp.jsonrpc")
local validate = require("mcp.validate").validate

local Server = {}
Server.__index = Server

-- Protocol versions we understand. We echo the client's requested version when it's
-- one of these, otherwise we answer with our latest (the JS SDK does the same dance).
local LATEST_PROTOCOL_VERSION = "2025-11-25"
local SUPPORTED_PROTOCOL_VERSIONS = {
	["2025-11-25"] = true,
	["2025-06-18"] = true,
	["2025-03-26"] = true,
	["2024-11-05"] = true,
	["2024-10-07"] = true,
}

function Server.new(info)
	info = info or {}
	return setmetatable({
		name = info.name or "mcp-lua-server",
		version = info.version or "0.0.0",
		instructions = info.instructions,
		tools = {}, -- name -> { name, description, inputSchema, handler }
		toolOrder = {}, -- registration order, for a stable tools/list
		initialized = false,
		transport = nil,
	}, Server)
end

-- Register a tool. `inputSchema` is a plain JSON Schema table (defaults to an empty
-- object schema). `handler(args, extra)` returns a CallToolResult table:
--   { content = { { type = "text", text = "..." } }, isError = false }
-- Returns self for chaining.
function Server:tool(name, description, inputSchema, handler)
	if type(name) ~= "string" or name == "" then
		error("tool() requires a non-empty string name", 2)
	end
	if type(handler) ~= "function" then
		error("tool('" .. name .. "') requires a handler function", 2)
	end
	if self.tools[name] == nil then
		self.toolOrder[#self.toolOrder + 1] = name
	end
	self.tools[name] = {
		name = name,
		description = description or "",
		inputSchema = inputSchema or { type = "object", properties = json.object({}) },
		handler = handler,
	}
	return self
end

-- Alias matching the JS SDK's newer name.
Server.registerTool = Server.tool

-- Normalise a tool's inputSchema for the wire: guarantee type=object and that an
-- (absent or empty) `properties` serialises as a JSON object, not an array.
local function wireSchema(schema)
	local out = { type = schema.type or "object" }
	out.properties = schema.properties and json.object(schema.properties) or json.object({})
	if schema.required ~= nil then
		out.required = schema.required
	end
	if schema.additionalProperties ~= nil then
		out.additionalProperties = schema.additionalProperties
	end
	return out
end

-- Coerce a thrown handler error into a CallToolResult flagged isError, matching the
-- JS SDK: tool failures are reported in-band so the model can see and self-correct,
-- rather than as JSON-RPC protocol errors.
local function errorResult(message)
	return {
		content = { { type = "text", text = tostring(message) } },
		isError = true,
	}
end

-- Method handlers. Each receives (self, params) and returns a result table (or nil
-- for notifications). Throwing here becomes a JSON-RPC INTERNAL_ERROR.
local methods = {}

function methods.initialize(self, params)
	local requested = params and params.protocolVersion
	local protocolVersion = (requested and SUPPORTED_PROTOCOL_VERSIONS[requested]) and requested
		or LATEST_PROTOCOL_VERSION
	local result = {
		protocolVersion = protocolVersion,
		capabilities = { tools = json.object({}) },
		serverInfo = { name = self.name, version = self.version },
	}
	if self.instructions then
		result.instructions = self.instructions
	end
	return result
end

function methods.ping()
	return json.object({})
end

methods["tools/list"] = function(self)
	local tools = {}
	for _, name in ipairs(self.toolOrder) do
		local t = self.tools[name]
		tools[#tools + 1] = {
			name = t.name,
			description = t.description,
			inputSchema = wireSchema(t.inputSchema),
		}
	end
	return { tools = tools }
end

-- tools/call returns either a CallToolResult, or (nil, code, message) to signal a
-- JSON-RPC error (unknown tool / invalid params), which _handleMessage turns into an
-- error response.
methods["tools/call"] = function(self, params)
	params = params or {}
	local tool = self.tools[params.name]
	if not tool then
		return nil, jsonrpc.errors.INVALID_PARAMS, "Tool not found: " .. tostring(params.name)
	end
	local args = params.arguments or {}
	local ok, err = validate(args, tool.inputSchema)
	if not ok then
		return nil, jsonrpc.errors.INVALID_PARAMS, "Invalid arguments: " .. tostring(err)
	end
	local okCall, resultOrErr = pcall(tool.handler, args, { name = params.name })
	if not okCall then
		return errorResult(resultOrErr)
	end
	if type(resultOrErr) ~= "table" then
		return errorResult("tool '" .. params.name .. "' returned a non-table result")
	end
	return resultOrErr
end

-- Notifications: no response. We accept the lifecycle one and ignore others.
local notifications = {
	["notifications/initialized"] = function(self)
		self.initialized = true
	end,
}

-- Route one decoded JSON-RPC message. Returns a response table to send, or nil for
-- notifications (and unknown notifications, which are silently ignored per spec).
-- Pure: no IO, so unit tests can drive it directly.
function Server:_handleMessage(msg)
	if type(msg) ~= "table" then
		return jsonrpc.error(nil, jsonrpc.errors.INVALID_REQUEST, "invalid request (not an object)")
	end

	-- Notification (no id): dispatch if known, never respond.
	if jsonrpc.isNotification(msg) then
		local fn = notifications[msg.method]
		if fn then
			pcall(fn, self, msg.params or {})
		end
		return nil
	end

	-- Anything else must look like a request.
	if msg.method == nil then
		return jsonrpc.error(msg.id, jsonrpc.errors.INVALID_REQUEST, "invalid request (no method)")
	end

	local handler = methods[msg.method]
	if not handler then
		return jsonrpc.error(msg.id, jsonrpc.errors.METHOD_NOT_FOUND, "method not found: " .. tostring(msg.method))
	end

	local ok, result, errCode, errMsg = pcall(handler, self, msg.params or {})
	if not ok then
		-- The handler itself threw — a server-internal fault.
		return jsonrpc.error(msg.id, jsonrpc.errors.INTERNAL_ERROR, tostring(result))
	end
	if result == nil and errCode ~= nil then
		-- Handler asked for a JSON-RPC error (e.g. unknown tool / invalid params).
		return jsonrpc.error(msg.id, errCode, errMsg)
	end
	return jsonrpc.result(msg.id, result)
end

-- Connect a transport and serve until it ends. The transport calls back with each
-- decoded message; we route it and send any response. Blocks (mirrors the JS
-- `await server.connect(transport)` lifetime for a stdio server).
function Server:connect(transport)
	self.transport = transport
	transport:start(function(msg)
		local response = self:_handleMessage(msg)
		if response ~= nil then
			transport:send(response)
		end
	end)
end

function Server:close()
	if self.transport then
		self.transport:close()
		self.transport = nil
	end
end

Server.LATEST_PROTOCOL_VERSION = LATEST_PROTOCOL_VERSION
Server.SUPPORTED_PROTOCOL_VERSIONS = SUPPORTED_PROTOCOL_VERSIONS

return Server
