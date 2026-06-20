-- tools/trade.lua — live account (OAuth/character import) + trade (leagues, currency,
-- search, pricing). The character-import and trade tools are ASYNC: PoB's networking is
-- callback-driven, so the bridge returns a jobId and we poll jobPoll (async=true here →
-- bridge.callJob). accountStatus + searchTradeStats are synchronous reads.
local S = require("tools.schema")

return function(ctx)
	ctx.register({
		name = "gui_account_status",
		method = "accountStatus",
		description = "Check whether PoB is signed in to the Path of Exile API (a prerequisite for "
			.. "gui_list_characters / gui_import_character). Read-only and network-free — it reads the "
			.. "persisted OAuth token. If signed out, it tells the user to authorise once in PoB's "
			.. "Import tab (the MCP can't drive the interactive browser login). Never exposes the token.",
		schema = S.obj({}),
	})

	ctx.register({
		name = "gui_list_characters",
		method = "listCharacters",
		async = true,
		description = "List the Path of Exile 2 characters on the signed-in account (name, class, ascendancy, "
			.. "level, league). Read-only — use it to pick the character to import and analyze. Requires "
			.. "PoB signed in (check gui_account_status first). Live API call, so it may take a moment.",
		schema = S.obj({}),
	})

	ctx.register({
		name = "gui_import_character",
		method = "importCharacter",
		async = true,
		description = "Import one of the account's PoE2 characters (passive tree, jewels, equipment, skills) into "
			.. "the LIVE build and return the recalculated stats — the 'pull in my real character and tell "
			.. "me what to fix' tool. (Spans tree/items/skills, so a full revert needs a gui_undo per "
			.. "affected scope — see the returned `undoNote`.) Requires PoB signed in (see gui_account_status). "
			.. "By default it REPLACES the current tree/items/skills; set the clear*/import* flags to merge "
			.. "or import only part. Live API call; may take a moment.",
		schema = S.obj({
			name = S.str("Exact character name to import (from gui_list_characters)."),
			importItems = S.bool("Import equipment + skills (default true)."),
			importTree = S.bool("Import passive tree + jewels (default true)."),
			clearItems = S.bool("Delete existing equipment before importing (default true)."),
			clearSkills = S.bool("Delete existing skills before importing (default true)."),
			clearJewels = S.bool("Delete existing jewels before importing (default true)."),
			ignoreWeaponSwap = S.bool("Skip items/skills in the weapon-swap set (default false)."),
			stats = S.arr(S.str(), "Specific mainOutput keys to return after import; omit for a curated default set."),
		}, { "name" }),
	})

	ctx.register({
		name = "gui_list_leagues",
		method = "listLeagues",
		async = true,
		description = "List the Path of Exile 2 trade leagues for the realm (e.g. the current challenge league, "
			.. "Standard, Hardcore). Read-only. Call this first to get the exact league name the other "
			.. "trade tools need. Live API call.",
		schema = S.obj({}),
	})

	ctx.register({
		name = "gui_currency_rates",
		method = "currencyRates",
		async = true,
		description = "Get current currency→divine exchange rates for a league (poe.ninja economy), so budgets and "
			.. "prices can be reasoned about in one unit. Cached ~1h in memory; pass refresh=true to force a "
			.. "re-fetch. Returns a map of currencyId → value-in-divines.",
		schema = S.obj({
			league = S.str("League name (from gui_list_leagues)."),
			refresh = S.bool("Force a fresh poe.ninja fetch instead of the cache."),
		}, { "league" }),
	})

	ctx.register({
		name = "gui_search_trade_stats",
		method = "searchTradeStats",
		description = "Discover trade-site stat-filter IDs to feed gui_search_trade's `stats` (the catalogue has "
			.. "8000+ entries, so this is the 'search before you query' step). Filter by text substring and "
			.. "optional category. Read-only. Example: query 'maximum life' → `explicit.stat_3299347043`.",
		schema = S.obj({
			query = S.str("Case-insensitive substring of the stat text (e.g. 'fire resistance', 'maximum life')."),
			type = S.str("Restrict to a category: explicit, implicit, pseudo, rune, enchant, crafted, fractured, desecrated, sanctum, skill."),
			limit = S.int("Max results (default 40)."),
		}),
	})

	ctx.register({
		name = "gui_search_trade",
		method = "searchTrade",
		async = true,
		description = "Search the PoE2 trade site by explicit criteria and return the top listings (price, the seller "
			.. "whisper, item text) plus `tradeUrl` — the canonical trade-site link for this exact search, which "
			.. "you should give the user so they can open it in-browser to view and purchase the items. For mod "
			.. "filters, pass `stats` as {id,min?,max?} using IDs from gui_search_trade_stats. Budget-capped via "
			.. "budget+currency. Prices gain a `divEquivalent` once gui_currency_rates has been called for the "
			.. "league. Read-only — never trades.",
		schema = S.obj({
			league = S.str("League name (from gui_list_leagues)."),
			category = S.str("Trade category option, e.g. 'accessory.ring', 'armour.chest', 'weapon.wand'. Omit for any."),
			rarity = S.str("Rarity option: normal, magic, rare, unique, nonunique. Omit for any."),
			online = S.bool("Online sellers only (default true)."),
			budget = S.num("Max price; pair with `currency`."),
			currency = S.str("Budget currency id (default 'divine'), e.g. 'divine', 'exalted', 'chaos'."),
			minLevel = S.num("Min character level requirement."),
			maxLevel = S.num("Max character level requirement."),
			minItemLevel = S.num("Min item level."),
			maxItemLevel = S.num("Max item level."),
			corrupted = S.bool("Filter by corrupted state."),
			sockets = S.num("Minimum rune socket count."),
			stats = S.arr({
				type = "object",
				properties = { id = S.str("Trade stat id from gui_search_trade_stats."), min = S.num(), max = S.num() },
				required = { "id" },
			}, "Explicit mod filters (AND). Each {id,min?,max?}."),
			limit = S.int("Max listings to return (default 10)."),
		}, { "league" }),
	})

	ctx.register({
		name = "gui_price_item",
		method = "priceItem",
		async = true,
		description = "Estimate the market price of an EQUIPPED item by searching comparable listings. Maps the item's "
			.. "explicit mods to trade stat filters (each at valueFraction × its current roll) plus its base "
			.. "category, searches, and returns a divine min/median/max over the results (auto-loads currency "
			.. "rates). A well-rolled rare may match few/no listings — check modsMatched/sampleSize. Read-only.",
		schema = S.obj({
			league = S.str("League name (from gui_list_leagues)."),
			slot = S.str("Equipment slot to price, e.g. 'Ring 1', 'Body Armour', 'Amulet', 'Weapon 1'."),
			valueFraction = S.num("Fraction of each mod's current roll to require as the min filter (default 0.9; lower = looser/more results)."),
			rarity = S.str("Override rarity option; defaults to the item's own rarity."),
			budget = S.num("Optional max price cap; pair with `currency`."),
			currency = S.str("Budget currency id (default 'divine')."),
			online = S.bool("Online sellers only (default true)."),
			limit = S.int("Max comparable listings to sample (default 10)."),
		}, { "league", "slot" }),
	})
end
