-- mcp — a standalone Lua implementation of the Model Context Protocol server,
-- mirroring the JavaScript SDK (@modelcontextprotocol/sdk).
--
--   local mcp = require("mcp")
--   local server = mcp.Server.new({ name = "echo", version = "0.1.0" })
--   server:tool("echo", "Echo back the text.",
--     { type = "object", properties = { text = { type = "string" } }, required = { "text" } },
--     function(args) return { content = {{ type = "text", text = args.text }} } end)
--   server:connect(mcp.StdioServerTransport.new())   -- blocks, serving stdio

local M = {}

M.VERSION = "0.1.0"

M.Server = require("mcp.server")
M.StdioServerTransport = require("mcp.transport.stdio")
M.json = require("mcp.json")
M.jsonrpc = require("mcp.jsonrpc")
M.errors = M.jsonrpc.errors
M.validate = require("mcp.validate").validate

return M
