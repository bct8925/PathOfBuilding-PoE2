-- tools/schema.lua — tiny JSON Schema constructors so tool definitions stay readable.
-- Each returns a plain JSON Schema table (the format mcp-lua advertises in tools/list
-- and validates tools/call against). `description` is carried per-property like zod's
-- .describe() so the client sees per-argument docs.

local S = {}

local function withDesc(t, desc)
	if desc then
		t.description = desc
	end
	return t
end

function S.str(desc) return withDesc({ type = "string" }, desc) end
function S.int(desc) return withDesc({ type = "integer" }, desc) end
function S.num(desc) return withDesc({ type = "number" }, desc) end
function S.bool(desc) return withDesc({ type = "boolean" }, desc) end
function S.arr(items, desc) return withDesc({ type = "array", items = items }, desc) end
function S.enum(values, desc) return withDesc({ type = "string", enum = values }, desc) end
function S.object(desc) return withDesc({ type = "object" }, desc) end

-- A scalar that may be boolean/number/string (zod union), optionally clearable.
function S.scalar(desc) return withDesc({ type = { "boolean", "number", "string" } }, desc) end

-- obj(properties, required?) — top-level (or nested) object schema.
function S.obj(properties, required)
	return { type = "object", properties = properties, required = required }
end

-- The ubiquitous optional `stats` array used by most mutating tools.
S.STATS = S.arr(S.str(), "Stat keys to return after recalc.")

return S
