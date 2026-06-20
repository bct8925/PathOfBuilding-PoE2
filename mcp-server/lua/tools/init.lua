-- tools/init.lua — register every tool on the server.
--
-- Returns a function(server, deps) where deps = { bridge, engine, optimize, json }.
-- Each domain module is `function(ctx)` and calls ctx.register{...}. A spec is one of:
--   { name, description, schema, handler }            -- custom handler (compute, optimize)
--   { name, description, schema, method }             -- forward to bridge.call(method, args)
--   { name, description, schema, method, async=true } -- forward to bridge.callJob(method, args)
-- Tool arg names match the bridge param names 1:1, so handlers just pass `args` through.

local MODULES = { "read", "config", "tree", "items", "skills", "lifecycle", "trade", "optimize" }

return function(server, deps)
	local register = function(spec)
		local handler = spec.handler
		if not handler then
			local method = assert(spec.method, "tool '" .. tostring(spec.name) .. "' needs a method or handler")
			if spec.async then
				handler = function(args) return deps.bridge.callJob(method, args) end
			else
				handler = function(args) return deps.bridge.call(method, args) end
			end
		end
		server:tool(spec.name, spec.description, spec.schema, handler)
	end

	local ctx = {
		register = register,
		bridge = deps.bridge,
		engine = deps.engine,
		optimize = deps.optimize,
		json = deps.json,
	}

	for _, mod in ipairs(MODULES) do
		require("tools." .. mod)(ctx)
	end

	return server
end
