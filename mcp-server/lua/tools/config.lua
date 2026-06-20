-- tools/config.lua — Configuration-tab read/write tools.
local S = require("tools.schema")

return function(ctx)
	ctx.register({
		name = "gui_get_config",
		method = "getConfig",
		description = "List the live build's Configuration-tab options with their current values, a per-option "
			.. "`isDefault` flag, and (for dropdowns) the valid choices — so you use real `var` names "
			.. "and values with gui_set_config instead of guessing. The catalog is large, so results "
			.. "are PAGINATED (default 60; use `offset`/`limit`, or `query` to filter by var/label). "
			.. "Pass `modifiedOnly` to get just the options the user actually changed from default — "
			.. "the fast way to explain a surprising DPS/EHP number. Read-only.",
		schema = S.obj({
			query = S.str("Filter options by var name or label text (e.g. 'boss', 'life', 'resist')."),
			modifiedOnly = S.bool("Return only options whose value differs from the default (user-set toggles)."),
			limit = S.int("Max options to return (default 60)."),
			offset = S.int("Pagination offset (default 0)."),
		}),
	})

	ctx.register({
		name = "gui_set_config",
		method = "setConfig",
		description = "Set or toggle a Configuration-tab option on the live build (e.g. enemy settings, "
			.. "buffs, conditions), then recalc and return the refreshed stats. `var` is the "
			.. "internal config variable name; `value` is a boolean, number, or string (omit to clear).",
		schema = S.obj({
			var = S.str("Internal config variable name (e.g. 'enemyIsBoss', 'conditionFullLife')."),
			value = S.scalar("New value; omit/null to clear the option."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}, { "var" }),
	})
end
