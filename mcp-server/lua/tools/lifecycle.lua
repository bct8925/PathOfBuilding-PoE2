-- tools/lifecycle.lua — undo/redo + build new/save/save-as.
local S = require("tools.schema")

return function(ctx)
	ctx.register({
		name = "gui_undo",
		method = "undo",
		description = "Undo the last change on the live build using PoB's native per-tab undo stack. "
			.. "Scope selects the tab (tree/config/items/skills); omit to use the tab of the "
			.. "last MCP mutation.",
		schema = S.obj({
			scope = S.enum({ "tree", "config", "items", "skills" }, "Which tab's undo stack to use; defaults to the last MCP-mutated scope."),
			stats = S.arr(S.str()),
		}),
	})

	ctx.register({
		name = "gui_redo",
		method = "redo",
		description = "Redo the last undone change on the live build (PoB's native per-tab redo stack). "
			.. "Scope selects the tab; omit to use the tab of the last MCP mutation.",
		schema = S.obj({
			scope = S.enum({ "tree", "config", "items", "skills" }, "Which tab's redo stack to use; defaults to the last MCP mutation."),
			stats = S.arr(S.str()),
		}),
	})

	ctx.register({
		name = "gui_build_lifecycle",
		method = "lifecycle",
		description = "Manage the live build's lifecycle. action='new' replaces the current build with "
			.. "a fresh one (optionally setting class/ascendancy/level) — this DISCARDS the "
			.. "current build's unsaved changes, so save first if needed. action='save' writes "
			.. "to the build's existing file (errors if never saved). action='saveAs' saves "
			.. "under a new name (into PoB's Builds folder, optional subfolder), updating the "
			.. "build's name/path.",
		schema = S.obj({
			action = S.enum({ "new", "save", "saveAs" }, "'new' (fresh build), 'save' (existing file), or 'saveAs' (new name)."),
			name = S.str("Build name: required for saveAs; the new build's name for 'new' (default 'Unnamed build')."),
			subPath = S.str("Optional subfolder under the Builds folder for saveAs (e.g. 'Witch/'). Include the trailing slash."),
			className = S.str("For 'new': starting class name (e.g. 'Witch')."),
			ascendancy = S.str("For 'new': starting ascendancy name."),
			level = S.int("For 'new': starting character level (1-100)."),
			stats = S.arr(S.str(), "Stat keys to return after recalc (action='new')."),
		}, { "action" }),
	})
end
