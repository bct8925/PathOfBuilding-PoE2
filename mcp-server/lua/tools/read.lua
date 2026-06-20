-- tools/read.lua — read/analyze tools (headless compute + live read-only queries).
local S = require("tools.schema")

return function(ctx)
	-- Headless: stateless calc (spawns luajit per call). Custom handler (not the bridge).
	ctx.register({
		name = "compute_build_stats",
		description = "Compute Path of Building 2 stats for a build headlessly. Pass a PoB build XML "
			.. "to evaluate it, or omit it to compute the default empty build. Returns key "
			.. "offence/defence stats (DPS, Life, ES, resistances, crit, …).",
		schema = S.obj({
			buildXml = S.str("Full PoB build XML. Omit for the default empty build."),
			name = S.str("Display name for the loaded build."),
			stats = S.arr(S.str(), "Specific mainOutput keys to return; omit for a curated default set."),
		}),
		handler = function(args)
			local result = ctx.engine.compute({ buildXml = args.buildXml, name = args.name, stats = args.stats })
			return {
				content = { { type = "text", text = ctx.json.encode(result, { indent = true }) } },
				isError = not result.ok,
			}
		end,
	})

	ctx.register({
		name = "gui_get_build",
		method = "getBuild",
		description = "Read the live PoB2 build: identity (class, ascendancy, level, main skill), "
			.. "key computed stats (DPS, Life/ES/Mana, EHP, resistances, crit, speed), and the passive "
			.. "`points` budget (used / total / remaining, + ascendancy used/total). NOTE: "
			.. "`ascendancyTotal`/`ascendancyRemaining` are the 8-point CAP, not unlocked points — some "
			.. "require completing Trials (PoB can't tell), so confirm Trial progress with the user "
			.. "before recommending spending 'remaining' ascendancy points (see `ascendancyNote`). "
			.. "If you pass `stats`, any requested key the build doesn't produce comes back in "
			.. "`unknownStats` (so you can tell an invalid key from a genuine zero — use "
			.. "gui_get_stat_keys to discover valid keys). Requires PoB running with the bridge on.",
		schema = S.obj({
			stats = S.arr(S.str(), "Specific mainOutput stat keys to return; omit for a curated default set."),
			includeNotables = S.bool("Include the full allocated Notable/Keystone list (heavy; default false)."),
		}),
	})

	ctx.register({
		name = "gui_get_stat_keys",
		method = "getStatKeys",
		description = "Discover the calc output stat keys the live build currently produces (the mainOutput "
			.. "equivalent of gui_get_config) so you pass REAL keys to gui_get_build / gui_explain_stat "
			.. "instead of guessing. Read-only. Returns each scalar key with its current value, "
			.. "optionally filtered by a `query` substring, plus the curated default set.",
		schema = S.obj({
			query = S.str("Case-insensitive substring to filter key names (e.g. 'dps', 'resist', 'freeze')."),
			limit = S.int("Max keys to return (default 250)."),
		}),
	})

	ctx.register({
		name = "gui_explain_stat",
		method = "explainStat",
		description = "Explain how a computed stat on the live build was derived (PoB Calcs-tab-style "
			.. "breakdown): base value, increased/reduced and more/less multipliers, and any "
			.. "contributing rows. `stat` is an internal output key (e.g. 'Life', 'FireResist', "
			.. "'CritChance', 'TotalDPS'). Read-only.",
		schema = S.obj({
			stat = S.str("Output key to break down (e.g. 'Life', 'TotalDPS', 'CritChance')."),
		}, { "stat" }),
	})

	ctx.register({
		name = "gui_explain_skill",
		method = "explainSkill",
		description = "Break down a SKILL numerically so you can validate a build's damage thesis instead of "
			.. "inferring it from item text. Returns the skill's name + flags, hit damage by damage "
			.. "type (the result of any conversion) with overall min/max/average + chance to hit, "
			.. "crit chance/multiplier, attack/cast speed, hit and DoT/ailment DPS, and an `ailments` "
			.. "map of every freeze/chill/shock/ignite/bleed/poison chance, effect, and duration the "
			.. "calc exposes (e.g. FreezeChanceOnHit, ShockEffect). MULTI-PART skills (slams like "
			.. "Earthshatter, multi-stage skills) compute one part at a time, so the DPS is part-"
			.. "SPECIFIC: the response carries `skillPartIndex`, `skillPartCount`, and a `skillParts` "
			.. "list — when count > 1, enumerate parts (a low number is often just the wrong part) and "
			.. "read a specific one with `part` (a 1-based index, evaluated WITHOUT changing the live "
			.. "selection; switch it for real with gui_set_main_skill { part }). Defaults to the main "
			.. "skill; pass a 1-based `group` to read another socket group WITHOUT switching the main "
			.. "skill. Read-only.",
		schema = S.obj({
			group = S.int("1-based socket group index to explain; omit for the current main skill."),
			part = S.int("1-based skill-part index to read (multi-part skills); omit for the currently-selected part. Does NOT change the live selection."),
		}),
	})

	ctx.register({
		name = "gui_query_mods",
		method = "queryMods",
		description = "Inspect the raw modifier database behind a stat — the deep 'why' (FR-7). With a "
			.. "`query` substring, lists matching internal mod names (e.g. search 'Life' or "
			.. "'Resist' to find the exact name). With an exact `mod`, returns every "
			.. "contributing modifier — its type (BASE/INC/MORE/FLAG…), value, source "
			.. "(Tree/Item/Config/…), and `gates` (each conditional tag RESOLVED to its condition/"
			.. "multiplier/skill name + the condition's current truth value) — plus two summaries: "
			.. "`sum*` are UNCONDITIONAL totals (gated mods excluded, so sumInc can read 0 while real "
			.. "but condition-gated increases sit in the list), and `sum*Active` are the same sums in "
			.. "the main skill's context (gated mods included). Read-only.",
		schema = S.obj({
			mod = S.str("Exact internal mod name to break down (e.g. 'Life', 'FireResistance', 'Damage')."),
			query = S.str("Substring to find mod names when you don't know the exact one. Omit both to list all."),
			limit = S.num("Max mod names to return in discovery mode (default 50)."),
		}),
	})
end
