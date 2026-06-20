-- mcp.validate — a minimal JSON Schema validator for tool inputs.
--
-- Deliberately small: covers the subset MCP tool input schemas actually use —
-- `type` (object/array/string/number/integer/boolean/null), `required`,
-- `properties`, `enum`, and `items` (array element type). It is enough to reject
-- the common client mistakes (missing required field, wrong scalar type) with a
-- clear INVALID_PARAMS message; handlers can still defend themselves for anything
-- deeper. Returns `true` on success, or `false, errString` on the first violation.

local M = {}

-- JSON-type name of a Lua value, matching how it round-trips through dkjson.
-- Note: Lua can't tell an empty array from an empty object, so an empty table is
-- reported as "object" here (the common case for a params table).
local function jsonTypeOf(v)
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" then
		return "boolean"
	elseif t == "number" then
		return "number"
	elseif t == "string" then
		return "string"
	elseif t == "table" then
		-- Sequence with at least one element → array; otherwise object.
		if v[1] ~= nil then
			return "array"
		end
		return "object"
	end
	return t
end

-- Does a value satisfy a schema's `type` (which may be a string or a list)?
local function typeMatches(value, schemaType)
	local actual = jsonTypeOf(value)
	local function ok(expected)
		if expected == "integer" then
			return type(value) == "number" and math.floor(value) == value
		end
		if expected == "number" then
			return type(value) == "number"
		end
		-- An empty table can be either array or object; accept both.
		if (expected == "array" or expected == "object") and type(value) == "table" and value[1] == nil then
			return true
		end
		return actual == expected
	end
	if type(schemaType) == "table" then
		for _, t in ipairs(schemaType) do
			if ok(t) then
				return true
			end
		end
		return false
	end
	return ok(schemaType)
end

local function validate(value, schema, path)
	path = path or "$"
	if type(schema) ~= "table" then
		return true
	end

	if schema.type ~= nil and value ~= nil then
		if not typeMatches(value, schema.type) then
			local want = type(schema.type) == "table" and table.concat(schema.type, "/") or schema.type
			return false, ("%s: expected %s, got %s"):format(path, want, jsonTypeOf(value))
		end
	end

	if schema.enum ~= nil and value ~= nil then
		local found = false
		for _, allowed in ipairs(schema.enum) do
			if allowed == value then
				found = true
				break
			end
		end
		if not found then
			return false, ("%s: value not in enum"):format(path)
		end
	end

	-- Object: required keys + per-property schemas.
	if type(value) == "table" then
		if schema.required then
			for _, key in ipairs(schema.required) do
				if value[key] == nil then
					return false, ("%s: missing required field '%s'"):format(path, key)
				end
			end
		end
		if schema.properties then
			for key, subschema in pairs(schema.properties) do
				if value[key] ~= nil then
					local ok, err = validate(value[key], subschema, path .. "." .. key)
					if not ok then
						return false, err
					end
				end
			end
		end
		-- Array: validate each element against `items`.
		if schema.items and value[1] ~= nil then
			for i, elem in ipairs(value) do
				local ok, err = validate(elem, schema.items, ("%s[%d]"):format(path, i))
				if not ok then
					return false, err
				end
			end
		end
	end

	return true
end

-- validate(value, schema) -> true | false, errString
function M.validate(value, schema)
	return validate(value, schema, "$")
end

return M
