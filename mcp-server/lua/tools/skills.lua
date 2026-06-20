-- tools/skills.lua — socket groups + gems (active skills and supports).
local S = require("tools.schema")

return function(ctx)
	ctx.register({
		name = "gui_get_skills",
		method = "getSkills",
		description = "Read the live build's socket groups and their gems so you can target gem tools by "
			.. "real indices (don't guess). Returns each group with its 1-based index, label, slot, "
			.. "enabled, whether it's the main group, its resolved main skill name, its gems "
			.. "(each with a 1-based index, name, level, quality, enabled, `support` true/false for "
			.. "active-vs-support, and `tags`), and `derived` — true if "
			.. "the group's skill is GRANTED by an item or passive node (not hand-socketed). Do NOT "
			.. "edit derived groups: the gem tools can't meaningfully change them and they VANISH "
			.. "(shifting later indices) if you unequip the item or deallocate the node. Read-only.",
		schema = S.obj({}),
	})

	ctx.register({
		name = "gui_search_gems",
		method = "searchGems",
		description = "Browse PoB's GEM database to find which active skills and support gems exist and what "
			.. "they DO, before adding them with gui_add_gem (don't guess names or tiers). Read-only. "
			.. "Matches `query` (case-insensitive) against the gem name, family, tag string, and effect "
			.. "description; `type` filters by tag/gemType substring (e.g. 'Attack', 'Spell', 'Cold', "
			.. "'Projectile', 'Minion'); `support` restricts to support gems (true) or active skills "
			.. "(false). PoE2 gems are TIERED — a family like 'Fire Penetration' returns 'Fire "
			.. "Penetration I', 'II', … so you can pass the exact name to gui_add_gem. Each result has "
			.. "name, gemType, support, tier, tags, requirements, naturalMaxLevel, and a description. "
			.. "Pass `compatibleWithGroup` (a 1-based socket group index) to return ONLY support gems "
			.. "PoB will actually let support that group's active skill — so you never add a support the "
			.. "calc silently ignores.",
		schema = S.obj({
			query = S.str("Case-insensitive text matched against gem name, family, tags, and description (e.g. 'penetration', 'minion', 'Ice Nova')."),
			type = S.str("Filter by tag/gemType substring (e.g. 'Attack', 'Spell', 'Cold', 'Projectile', 'Aura', 'Minion')."),
			support = S.bool("true = only support gems; false = only active skills; omit = both."),
			compatibleWithGroup = S.int("1-based socket group index: return only support gems compatible with that group's active skill."),
			includeDescription = S.bool("Include each gem's effect description (default true)."),
			limit = S.int("Max results to return (default 30)."),
		}),
	})

	ctx.register({
		name = "gui_set_main_skill",
		method = "setMainSkill",
		description = "Set which socket group is the live build's main skill (and optionally which "
			.. "active skill within it, and which PART of a multi-part skill), then recalc. `group` is "
			.. "the 1-based socket group index. For a multi-part skill (slams like Earthshatter, multi-"
			.. "stage skills) pass `part` (1-based; discover the parts + counts via gui_explain_skill) "
			.. "to switch which part the build's DPS reflects — e.g. the shatter vs the slam.",
		schema = S.obj({
			group = S.int("1-based socket group index to make the main skill."),
			activeSkill = S.int("1-based active-skill index within the group (for multi-skill gems)."),
			part = S.int("1-based skill-part index to select (multi-part skills; see gui_explain_skill's skillParts)."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}, { "group" }),
	})

	ctx.register({
		name = "gui_create_socket_group",
		method = "createSocketGroup",
		description = "Create a socket group on the live build and (optionally) populate the WHOLE link in one "
			.. "call via `gems` — an ordered list with the active skill first, then supports (each a "
			.. "name string or { name, level?, quality?, enabled? }). Avoids cannibalising a group and "
			.. "the ~6 round-trips of adding gems one at a time. Optionally label it, assign a `slot`, "
			.. "include it in Full DPS, or make it the main group. Pair with gui_search_gems "
			.. "compatibleWithGroup to pick valid supports. Returns the new group index + its gems.",
		schema = S.obj({
			gems = S.arr({
				type = { "string", "object" },
				properties = {
					name = S.str(),
					level = S.int(),
					quality = S.int(),
					enabled = S.bool(),
				},
			}, "Ordered gems to add (active skill first, then supports); names or objects."),
			label = S.str("Optional group label."),
			slot = S.str("Optional equipment slot to associate (e.g. 'Body Armour')."),
			includeInFullDPS = S.bool("Count this group toward FullDPS (default false)."),
			setMain = S.bool("Make this the main socket group (default false)."),
			stats = S.arr(S.str(), "Stat keys to return after recalc (when gems are added)."),
		}),
	})

	ctx.register({
		name = "gui_set_socket_group",
		method = "setSocketGroup",
		description = "Set a socket group's properties on the live build, then recalc. Most important: "
			.. "`includeInFullDPS` — groups load with this OFF, which is why `FullDPS` reads 0 until "
			.. "you enable it for the skills you want counted. Also sets `enabled`, `label`, `slot`. "
			.. "Identify by 1-based `group` (omit for the main group). Won't edit item/node-derived groups.",
		schema = S.obj({
			group = S.int("1-based socket group index; omit for the main group."),
			includeInFullDPS = S.bool("Whether this group contributes to FullDPS."),
			enabled = S.bool("Enable/disable the whole group."),
			label = S.str("Set the group's label."),
			slot = S.str("Associate an equipment slot (empty string clears it)."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}),
	})

	ctx.register({
		name = "gui_add_gem",
		method = "addGem",
		description = "Add a gem (active skill or support) to the live build, resolved by name with "
			.. "PoB's fuzzy matcher. Adds to `group` (1-based index; omit to use the main group, "
			.. "or to create one if the build has none), or pass newGroup=true to start a fresh "
			.. "group. Then recalcs. PoE2 gems are tiered (e.g. 'Fire Penetration I'); ambiguous "
			.. "names return a clear error. Use gui_search_gems first to find the exact name/tier. "
			.. "The response echoes the group's full `gems` list so you can verify the result.",
		schema = S.obj({
			name = S.str("Gem name, e.g. 'Fireball', 'Fire Penetration I'."),
			group = S.int("1-based target socket group index; omit for the main group."),
			newGroup = S.bool("Add into a brand-new socket group instead of an existing one."),
			level = S.int("Gem level; omit for the gem's natural max."),
			quality = S.int("Gem quality (default 0)."),
			enabled = S.bool("Whether the gem is enabled (default true)."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}, { "name" }),
	})

	ctx.register({
		name = "gui_set_gem",
		method = "setGem",
		description = "Change a gem's level, quality, or enabled state on the live build, then recalc. "
			.. "Identify the gem by 1-based `index` OR by `name` within socket `group` (group omitted = "
			.. "main group); `name` avoids tracking indices that renumber after add/remove. "
			.. "If the engine clamps your request (e.g. tiered supports cap at level 1), the response "
			.. "sets `levelClamped: true` and a `note` with the actual value — it is NOT reported as success.",
		schema = S.obj({
			index = S.int("1-based gem index within the group (or use `name`)."),
			name = S.str("Gem name to target instead of index (e.g. 'Fire Penetration I')."),
			group = S.int("1-based socket group index; omit for the main group."),
			level = S.int("New gem level (clamped to the gem's valid range)."),
			quality = S.int("New gem quality."),
			enabled = S.bool("Enable/disable the gem."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}),
	})

	ctx.register({
		name = "gui_remove_gem",
		method = "removeGem",
		description = "Remove a gem from the live build by 1-based `index` OR by `name` within socket `group` "
			.. "(group omitted = main group), then recalc. Prefer `name` so you needn't track indices "
			.. "that renumber as you add/remove gems.",
		schema = S.obj({
			index = S.int("1-based gem index within the group (or use `name`)."),
			name = S.str("Gem name to remove instead of index (e.g. 'Fireball')."),
			group = S.int("1-based socket group index; omit for the main group."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}),
	})
end
