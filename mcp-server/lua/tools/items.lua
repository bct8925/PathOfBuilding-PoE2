-- tools/items.lua — equipment: read/search/add/equip/remove/replace/roll + jewel socketing.
local S = require("tools.schema")

return function(ctx)
	ctx.register({
		name = "gui_get_items",
		method = "getItems",
		description = "Read the live build's items so you can find an item's id and mod lines BEFORE editing "
			.. "(don't guess ids). Returns each EQUIPPED item with its slot, itemId, name, rarity, "
			.. "baseName, and explicit mod lines — each with a `modIndex` (the target for "
			.. "gui_set_item_roll), `ranged` (whether it's a rollable range), and its current "
			.. "`range`/`min`/`max`/`value` — plus implicits, enchants, and the item's raw text. "
			.. "Pass `slot` to read one slot, or includeInventory to also list unequipped items. Always "
			.. "returns `validSlots` (every equipment slot name, so you don't discover them by erroring); "
			.. "pass includeEmpty to also get `emptySlots` (which slots have nothing equipped). Read-only.",
		schema = S.obj({
			slot = S.str("Read only this slot (e.g. 'Amulet', 'Ring 1', 'Weapon 1'). Omit for all equipped items."),
			includeInventory = S.bool("Also list items in the build's set that aren't currently equipped (default false)."),
			includeEmpty = S.bool("Also return `emptySlots` — equipment slots with nothing equipped (default false)."),
			includeRaw = S.bool("Include each item's full raw text (default true)."),
		}),
	})

	ctx.register({
		name = "gui_search_items",
		method = "searchItems",
		description = "Browse PoB's UNIQUE item database to find a unique and read its abilities WITHOUT "
			.. "asking the user to paste item text. Read-only. Matches `query` (case-insensitive) "
			.. "against each unique's title, base, and mod lines, with an optional `type` filter "
			.. "(substring of item type, e.g. 'Amulet', 'Ring', 'Mace', 'Body Armour'). Each match "
			.. "returns its `name` (the 'Title, Base' handle — pass it to gui_add_item's `name`), "
			.. "title, baseName, itemType, level requirement, any `variants`, and its mod lines. "
			.. "If a unique isn't found here it isn't in PoB's data — ask the user for its text.",
		schema = S.obj({
			query = S.str("Case-insensitive text matched against unique name, base, and mods (e.g. 'Astramentis', 'crit')."),
			type = S.str("Filter by item type substring (e.g. 'Amulet', 'Ring', 'Mace', 'Body Armour')."),
			includeMods = S.bool("Include each unique's mod lines (default true)."),
			limit = S.int("Max results to return (default 25)."),
		}),
	})

	ctx.register({
		name = "gui_add_item",
		method = "addItem",
		description = "Add an item to the live build, then recalc. Provide EITHER `raw` (PoB item text) OR "
			.. "`name` to look up a UNIQUE in PoB's database (use gui_search_items first) — the "
			.. "named path fills in the unique's REAL mods, so you never guess or fabricate them. "
			.. "For a multi-variant unique, `variant` (1-based, from gui_search_items) picks which; "
			.. "it defaults to the current variant. Set equip=true for the natural slot, or pass an "
			.. "explicit `slot` (e.g. 'Amulet', 'Body Armour', 'Weapon 1', 'Ring 1'). Returns the id.",
		schema = S.obj({
			raw = S.str("Raw item text (Rarity:/name/base type/mod lines), the format PoB import uses."),
			name = S.str("Unique name to add from PoB's database (e.g. 'Astramentis'); alternative to raw."),
			variant = S.int("1-based variant index for a multi-variant unique (see gui_search_items)."),
			equip = S.bool("Equip to the item's natural slot (default false)."),
			slot = S.str("Explicit equipment slot to equip into (overrides natural slot)."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}),
	})

	ctx.register({
		name = "gui_equip_item",
		method = "equipItem",
		description = "Equip an already-added item (by its id) into a slot on the live build, then recalc. "
			.. "`slot` defaults to the item's natural primary slot.",
		schema = S.obj({
			itemId = S.int("Id of an item already in the build (from gui_add_item)."),
			slot = S.str("Equipment slot to equip into; omit for the natural slot."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}, { "itemId" }),
	})

	ctx.register({
		name = "gui_remove_item",
		method = "removeItem",
		description = "Remove an item (by id) from the live build entirely — also unequips it from any "
			.. "slot and clears jewel-socket references — then recalc.",
		schema = S.obj({
			itemId = S.int("Id of the item to remove."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}, { "itemId" }),
	})

	ctx.register({
		name = "gui_set_item_roll",
		method = "setItemRoll",
		description = "Adjust a ranged roll on an item's explicit modifier, then recalc. `range` is 0..1 "
			.. "(0 = the mod's minimum value, 1 = maximum). Only works on mods PoB knows are ranged "
			.. "(a '(min-max)' line); `modIndex` is the 1-based explicit-mod position.",
		schema = S.obj({
			itemId = S.int("Id of the item to edit."),
			modIndex = S.int("1-based index into the item's explicit mod lines."),
			range = S.num("Roll position from 0 (min) to 1 (max)."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}, { "itemId", "modIndex", "range" }),
	})

	ctx.register({
		name = "gui_replace_item",
		method = "replaceItem",
		description = "Replace an item in place with new raw text, preserving its slot(s) — the general "
			.. "'edit any item mod' tool: add/remove/change affixes, fix the base, etc. (beyond "
			.. "gui_set_item_roll, which only tunes an existing range). Workflow: read the item "
			.. "with gui_get_items (use its `raw`), edit the text (e.g. add a '+(min-max)% to Cold "
			.. "Resistance' line), and send it here. The new item is equipped wherever the old one "
			.. "was; the swap is a single undo. Keep a compatible base type for an equipped item.",
		schema = S.obj({
			itemId = S.int("Id of the item to replace (from gui_get_items)."),
			raw = S.str("The full new raw item text (Rarity:/name/base/mod lines), as from gui_get_items `raw`."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}, { "itemId", "raw" }),
	})

	ctx.register({
		name = "gui_socket_jewel",
		method = "socketJewel",
		description = "Place a jewel into (or clear) a passive-tree jewel socket on the live build, then "
			.. "recalc. `nodeId` is the socket node (from gui_get_jewel_sockets); `itemId` is a "
			.. "jewel already in the build (from gui_get_items / gui_add_item) — omit it to "
			.. "UNSOCKET. A jewel only takes effect when its socket node is allocated: if it "
			.. "isn't, the jewel is still placed but the response flags it inert (allocate the "
			.. "node with gui_set_passive). The change rides PoB's items undo stack.",
		schema = S.obj({
			nodeId = S.int("Socket node id (from gui_get_jewel_sockets)."),
			itemId = S.int("Id of a jewel already in the build to socket; omit to unsocket the slot."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}, { "nodeId" }),
	})
end
