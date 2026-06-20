-- mcp.json — JSON encode/decode for the MCP library.
--
-- Thin wrapper over the vendored dkjson (David Kolf's JSON module, MIT). Adds the
-- helpers the protocol needs to control the array-vs-object ambiguity of empty Lua
-- tables: dkjson encodes an empty `{}` as a JSON array `[]` unless the table carries
-- a `__jsontype='object'` metatable (dkjson.lua: the n==0 check in encode2). MCP
-- needs empty `properties`/`capabilities`/`ping` results to serialise as `{}`, so use
-- `json.object{}` for those and leave sequences (e.g. empty `required`) as plain tables.

local dkjson = require("mcp.vendor.dkjson")

local M = {}

-- Mark a table so it always serialises as a JSON object, even when empty.
function M.object(t)
	return setmetatable(t or {}, { __jsontype = "object" })
end

-- Mark a table as a JSON array. Non-empty sequences already encode as arrays; this is
-- mainly for symmetry/intent and is a no-op on the default dkjson sequence heuristic.
function M.array(t)
	return t or {}
end

-- A shared empty-object sentinel for results like `ping` → {} and `capabilities`.
M.EMPTY_OBJECT = M.object({})

-- encode(value) -> string. Compact (no indent) — MCP stdio is one JSON object per line.
function M.encode(value)
	return dkjson.encode(value)
end

-- decode(str) -> value, err. Returns (nil, errString) on malformed JSON. dkjson's
-- decode signature is (str, pos, nullval) -> value, pos, err; we surface value + err.
function M.decode(str)
	local value, _, err = dkjson.decode(str, 1, nil)
	if err then
		return nil, err
	end
	return value
end

M.null = dkjson.null

return M
