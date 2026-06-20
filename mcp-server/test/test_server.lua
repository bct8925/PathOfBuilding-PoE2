-- test/test_server.lua — unit tests for the Lua MCP server wiring (no GUI, no network).
-- Captures every registered tool spec, asserts the registry is complete and well-formed,
-- and drives each gui_* tool through a MOCK bridge to verify it forwards the right method
-- and passes args through. Also unit-tests the optimize scoring. Runs under luajit/lua5.1.

local here = (arg[0] or ""):gsub("[/\\][^/\\]*$", "")
if here == "" then here = "." end
local root = here .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/vendor/mcp-lua/?.lua;" .. root .. "/vendor/mcp-lua/?/init.lua;" .. package.path
local config = require("config")
package.path = config.RUNTIME_LUA .. "/?.lua;" .. config.RUNTIME_LUA .. "/?/init.lua;" .. package.path
package.cpath = config.RUNTIME_DIR .. "/?." .. (config.isWindows and "dll" or "so") .. ";" .. package.cpath

local optimizeMod = require("optimize")

-- Minimal assert harness.
local passed, failed = 0, 0
local function check(cond, msg)
	if cond then
		passed = passed + 1
		print("  ok - " .. msg)
	else
		failed = failed + 1
		print("  NOT OK - " .. msg)
	end
end

-- The canonical tool → bridge-method mapping (what each gui_* tool must forward to).
-- Mirrors the per-file `method`/`async` values; the test fails if any drift apart.
local EXPECTED = {
	gui_get_build = "getBuild", gui_get_stat_keys = "getStatKeys", gui_explain_stat = "explainStat",
	gui_explain_skill = "explainSkill", gui_query_mods = "queryMods",
	gui_get_config = "getConfig", gui_set_config = "setConfig",
	gui_search_passives = "searchPassives", gui_set_passive = "setPassive",
	gui_search_ascendancy = "searchAscendancy", gui_set_ascendancy = "setAscendancy",
	gui_get_jewel_sockets = "getJewelSockets", gui_set_class = "setClass",
	gui_get_tree_specs = "getTreeSpecs", gui_set_tree_version = "setTreeVersion", gui_select_spec = "selectSpec",
	gui_get_items = "getItems", gui_search_items = "searchItems", gui_add_item = "addItem",
	gui_equip_item = "equipItem", gui_remove_item = "removeItem", gui_set_item_roll = "setItemRoll",
	gui_replace_item = "replaceItem", gui_socket_jewel = "socketJewel",
	gui_get_skills = "getSkills", gui_search_gems = "searchGems", gui_set_main_skill = "setMainSkill",
	gui_create_socket_group = "createSocketGroup", gui_set_socket_group = "setSocketGroup",
	gui_add_gem = "addGem", gui_set_gem = "setGem", gui_remove_gem = "removeGem",
	gui_undo = "undo", gui_redo = "redo", gui_build_lifecycle = "lifecycle",
	gui_account_status = "accountStatus", gui_list_characters = "listCharacters",
	gui_import_character = "importCharacter", gui_list_leagues = "listLeagues",
	gui_currency_rates = "currencyRates", gui_search_trade_stats = "searchTradeStats",
	gui_search_trade = "searchTrade", gui_price_item = "priceItem",
}
local ASYNC = {
	listCharacters = true, importCharacter = true, listLeagues = true,
	currencyRates = true, searchTrade = true, priceItem = true,
}
local CUSTOM = { compute_build_stats = true, gui_optimize = true } -- non-bridge handlers

-- Capture specs by re-running the domain modules with a recording register.
local specs, byName = {}, {}
local mockBridge = {}
local function recordCall(kind)
	return function(method, params)
		mockBridge.last = { kind = kind, method = method, params = params }
		return { content = { { type = "text", text = "ok" } }, isError = false }
	end
end
mockBridge.call = recordCall("call")
mockBridge.callJob = recordCall("callJob")
mockBridge.raw = function() return { xml = "<x/>" } end

local ctx = {
	register = function(spec)
		specs[#specs + 1] = spec
		byName[spec.name] = spec
	end,
	bridge = mockBridge,
	engine = { compute = function() return { ok = true } end, search = function() return { ok = true, results = {} } end },
	optimize = optimizeMod,
	json = require("dkjson"),
}
for _, m in ipairs({ "read", "config", "tree", "items", "skills", "lifecycle", "trade", "optimize" }) do
	require("tools." .. m)(ctx)
end

print("# registry completeness")
check(#specs == 45, "registered 45 tools (got " .. #specs .. ")")
for _, spec in ipairs(specs) do
	check(type(spec.description) == "string" and #spec.description >= 10, spec.name .. " has a description")
	check(type(spec.schema) == "table" and spec.schema.type == "object", spec.name .. " has an object inputSchema")
	if not CUSTOM[spec.name] then
		check(EXPECTED[spec.name] ~= nil and spec.method == EXPECTED[spec.name],
			spec.name .. " → " .. tostring(spec.method))
		check((spec.async or false) == (ASYNC[spec.method] or false), spec.name .. " async flag correct")
	end
end

print("# mock-bridge dispatch (forwards method + passes args through)")
local function handlerFor(spec)
	if spec.handler then return spec.handler end
	if spec.async then return function(a) return mockBridge.callJob(spec.method, a) end end
	return function(a) return mockBridge.call(spec.method, a) end
end
for _, spec in ipairs(specs) do
	if not CUSTOM[spec.name] then
		mockBridge.last = nil
		local sentinel = { __sentinel = spec.name }
		handlerFor(spec)(sentinel)
		check(mockBridge.last and mockBridge.last.method == spec.method, spec.name .. " called bridge method " .. tostring(spec.method))
		check(mockBridge.last and mockBridge.last.params == sentinel, spec.name .. " forwarded args unchanged")
		check(mockBridge.last and mockBridge.last.kind == (spec.async and "callJob" or "call"), spec.name .. " used the right channel")
	end
end

print("# optimize scoring")
do
	local scored = optimizeMod.scoreTrials({
		{ label = "a", ok = true, stats = { TotalDPS = 100, FireResist = 80 } },
		{ label = "b", ok = true, stats = { TotalDPS = 200, FireResist = 70 } },
		{ label = "c", ok = false, error = "boom" },
	}, { maximize = "TotalDPS", constraints = { FireResist = { min = 75 } } })
	check(scored[1].feasible and not scored[2].feasible, "constraint feasibility (b violates FireResist)")
	check(not scored[3].feasible and scored[3].score == nil, "errored trial is infeasible, unscored")
	local winner, found = optimizeMod.pickWinner(scored)
	check(winner.label == "a" and found, "winner is the feasible 'a' even though 'b' scores higher")

	local infeasible = optimizeMod.scoreTrials({ { label = "x", ok = true, stats = { D = 5, R = 0 } } },
		{ maximize = "D", constraints = { R = { min = 75 } } })
	local w2, f2 = optimizeMod.pickWinner(infeasible)
	check(w2.label == "x" and not f2, "no-feasible falls back to best with feasibleFound=false")

	check(optimizeMod.scoreTrials({ { label = "m", ok = true, stats = { Reserved = 40 } } }, { minimize = "Reserved" })[1].score == -40,
		"minimize negates the stat")
	local wsum = optimizeMod.scoreTrials({ { label = "w", ok = true, stats = { A = 2, B = 3 } } },
		{ weights = { A = 10, B = 1 } })[1].score
	check(wsum == 23, "weighted blend 2*10 + 3*1 = 23")

	local d = optimizeMod.statDeltas({ Life = 100, ES = 50 }, { Life = 150, ES = 50 })
	check(d.Life and d.Life.delta == 50 and d.ES == nil, "statDeltas reports changed numeric stats only")
end

print(("\ntest_server: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
