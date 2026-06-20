-- mcp.jsonrpc — JSON-RPC 2.0 envelope helpers + standard error codes.
--
-- Mirrors the codes the JS SDK uses (@modelcontextprotocol/sdk types):
--   PARSE_ERROR -32700, INVALID_REQUEST -32600, METHOD_NOT_FOUND -32601,
--   INVALID_PARAMS -32602, INTERNAL_ERROR -32603.
-- A JSON-RPC *request* carries an `id`; a *notification* has no `id` and gets no
-- response. Responses are { jsonrpc="2.0", id, result } or
-- { jsonrpc="2.0", id, error={ code, message, data? } }.

local M = {}

M.VERSION = "2.0"

M.errors = {
	PARSE_ERROR = -32700,
	INVALID_REQUEST = -32600,
	METHOD_NOT_FOUND = -32601,
	INVALID_PARAMS = -32602,
	INTERNAL_ERROR = -32603,
}

-- True if a decoded message is a notification (a method call without an id).
function M.isNotification(msg)
	return type(msg) == "table" and msg.method ~= nil and msg.id == nil
end

-- True if a decoded message looks like a request (has a method and an id).
function M.isRequest(msg)
	return type(msg) == "table" and msg.method ~= nil and msg.id ~= nil
end

-- Build a success response for the given request id.
function M.result(id, result)
	return { jsonrpc = M.VERSION, id = id, result = result }
end

-- Build an error response. `id` may be nil (e.g. a parse error before we know it).
function M.error(id, code, message, data)
	local err = { code = code, message = message }
	if data ~= nil then
		err.data = data
	end
	return { jsonrpc = M.VERSION, id = id, error = err }
end

return M
