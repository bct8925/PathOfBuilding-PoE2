-- test_bridge.lua — headless exercise of the in-app MCP bridge dispatch logic.
--
-- Boots the full engine via HeadlessWrapper, loads Modules/MCPBridge, binds it to
-- the live `build`, and drives the JSON request/response path (Bridge:handleLine)
-- for getBuild / setConfig / setPassive / undo — the same code the live socket
-- bridge runs, minus the socket itself (LuaSocket isn't available on Linux).
--
-- Run from src/:
--   cd src && LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;" \
--     CI=true luajit ../mcp/lua/test_bridge.lua

local json = require("dkjson")

dofile("HeadlessWrapper.lua")
newBuild()
runCallback("OnFrame")

local Bridge = LoadModule("Modules/MCPBridge")
Bridge.build = build

local function call(method, params)
	local req = json.encode({ id = 1, method = method, params = params or {} })
	local resp = Bridge:handleLine(req)
	print("\n>>> " .. method .. " " .. json.encode(params or {}))
	print("<<< " .. json.encode(resp))
	return resp
end

local failed = false
local function check(cond, msg)
	if cond then
		print("  PASS: " .. msg)
	else
		failed = true
		print("  FAIL: " .. msg)
	end
end

-- 1. getBuild: identity + stats
local b = call("getBuild")
check(b.ok and b.result.className ~= nil, "getBuild returns a className")
check(b.result.stats ~= nil and b.result.stats.Life ~= nil, "getBuild returns Life stat")

-- 2. setConfig: toggle a boolean (check-type) option on, confirm it sticks
local cfgInput = build.configTab.configSets[build.configTab.activeConfigSetId].input
local c = call("setConfig", { var = "conditionFullLife", value = true })
check(c.ok and c.result.value == true, "setConfig conditionFullLife=true applied")
check(c.result.stats ~= nil, "setConfig returns refreshed stats")
check(cfgInput.conditionFullLife == true, "live config input reflects the change")

-- 2b. getConfig: discover config options + values (so set_config isn't a guess)
local gc = call("getConfig", { query = "life" })
check(gc.ok and gc.result.count >= 1, "getConfig lists options matching a query")
local fullLife
for _, o in ipairs(gc.result.options) do if o.var == "conditionFullLife" then fullLife = o end end
check(fullLife ~= nil and fullLife.type == "check", "getConfig returns conditionFullLife with its type")
local gcList = call("getConfig", { query = "resistance penalty" })
local listOpt
for _, o in ipairs(gcList.result.options) do if o.choices then listOpt = o end end
check(listOpt ~= nil and #listOpt.choices >= 2, "getConfig returns a list option's valid choices")

-- 3. undo (config scope inferred from last mutation) reverts it to the prior value
local u = call("undo")
check(u.ok and u.result.scope == "config", "undo used the config scope (last mutation)")
check(not cfgInput.conditionFullLife, "undo reverted conditionFullLife")

-- 4. setPassive: allocate a real node from the live tree, confirm alloc + count grows
local before = build.spec:CountAllocNodes()
local targetId
for id, node in pairs(build.spec.nodes) do
	-- pick a normal allocatable node that has a path and isn't already allocated
	if not node.alloc and node.path and node.type ~= "ClassStart" and node.type ~= "Mastery"
		and not node.ascendancyName then
		targetId = id
		break
	end
end
local baseLife = b.result.stats.Life
if targetId then
	local p = call("setPassive", { nodeId = targetId, alloc = true })
	check(p.ok and p.result.alloc == true, "setPassive allocated node " .. tostring(targetId))
	check(p.result.allocatedNodeCount > before, "allocated node count increased")
	check(p.result.stats ~= nil and p.result.stats.Life ~= baseLife, "setPassive changed Life stat live")

	-- undo the tree change: node count AND stats must revert to baseline
	local u2 = call("undo", { scope = "tree", stats = { "Life" } })
	check(u2.ok and u2.result.scope == "tree", "undo tree scope ok")
	check(u2.result.stats.Life == baseLife,
		"undo reverted Life to baseline (" .. tostring(baseLife) .. "), got " .. tostring(u2.result.stats.Life))
else
	print("  SKIP: no allocatable node found to test setPassive")
end

-- 5. tree discovery: getBuild readout, searchPassives, and the setPassive path
--    reporting + maxPath guard (the Stage-4 wrong-node fix).
check(type(b.result.allocatedNodeCount) == "number", "getBuild returns allocatedNodeCount")
-- P2: allocatedNotables is opt-in now (default omitted to keep the payload light)
check(b.result.allocatedNotables == nil, "getBuild omits allocatedNotables by default (opt-in)")
local bN = call("getBuild", { includeNotables = true })
check(type(bN.result.allocatedNotables) == "table", "getBuild returns allocatedNotables with includeNotables=true")

local sp = call("searchPassives", { query = "Life", maxDist = 8, limit = 10 })
check(sp.ok and type(sp.result.nodes) == "table", "searchPassives returns a nodes list")
check(sp.result.returned <= 10, "searchPassives honours limit")
if #sp.result.nodes >= 2 then
	local n1, n2 = sp.result.nodes[1], sp.result.nodes[2]
	check((n1.pathDist or 0) <= (n2.pathDist or 0), "searchPassives results are nearest-first")
	check(n1.id ~= nil and n1.name ~= nil, "searchPassives node carries id + name")
	check(n1.alloc == false, "searchPassives excludes already-allocated nodes by default")
end
for _, n in ipairs(call("searchPassives", { query = "Life", maxDist = 1 }).result.nodes) do
	check(n.pathDist ~= nil and n.pathDist <= 1, "maxDist=1 only returns nodes within 1 point")
	break
end

-- Find a node >= 2 points away to exercise path reporting + the maxPath guard.
local farNode
for _, n in ipairs(call("searchPassives", { query = "", maxDist = 20, limit = 200 }).result.nodes) do
	if n.pathDist and n.pathDist >= 2 then farNode = n; break end
end
if farNode then
	local cnt0 = build.spec:CountAllocNodes()
	local guarded = call("setPassive", { nodeId = farNode.id, alloc = true, maxPath = 1 })
	check(not guarded.ok and guarded.error:find("maxPath") ~= nil,
		"setPassive maxPath guard rejects a too-long path")
	check(build.spec:CountAllocNodes() == cnt0, "rejected setPassive allocated nothing")

	local taken = call("setPassive", { nodeId = farNode.id, alloc = true, stats = { "Life" } })
	check(taken.ok and taken.result.changedCount >= 2,
		"setPassive reports the full auto-allocated path (changedCount >= 2)")
	check(#taken.result.changedNodes == taken.result.changedCount,
		"changedCount matches changedNodes length")
	local tookTarget = false
	for _, n in ipairs(taken.result.changedNodes) do
		if n.id == farNode.id then tookTarget = true end
	end
	check(tookTarget, "changedNodes includes the requested target node")
	call("undo", { scope = "tree" }) -- restore baseline
else
	print("  SKIP: no node >= 2 points away to test path reporting")
end

-- 5a2. ascendancy vs regular tree are SEPARATE tools (FR-8): searchPassives excludes
--      ascendancy nodes; searchAscendancy/setAscendancy operate on the selected
--      ascendancy with its own 8-point budget; each set tool rejects the other's ids.
-- searchPassives must never surface an ascendancy node, regardless of selection.
local spReg = call("searchPassives", { query = "", maxDist = 30, limit = 400, includeAllocated = true })
local spHasAsc = false
for _, n in ipairs(spReg.result.nodes) do
	local nd = build.spec.nodes[n.id]
	if nd and nd.ascendancyName then spHasAsc = true; break end
end
check(not spHasAsc, "searchPassives excludes ascendancy nodes")

-- Find an ascendancy valid for the current class so we can select it (names vary by
-- patch, so discover one dynamically from the tree rather than hard-coding).
local ascKey
for key, entry in pairs(build.spec.tree.ascendNameMap or {}) do
	if entry.classId == build.spec.curClassId and (entry.ascendClassId or 0) > 0 then
		ascKey = key
		break
	end
end
if ascKey then
	local sc = call("setClass", { ascendancy = ascKey })
	check(sc.ok and build.spec.curAscendClassId ~= 0, "setClass selected ascendancy '" .. ascKey .. "'")
	local base = build.spec.curAscendClassBaseName

	local sa = call("searchAscendancy", { query = "", limit = 80, includeUnreachable = true })
	check(sa.ok and type(sa.result.nodes) == "table", "searchAscendancy returns a nodes list")
	check(sa.result.budget ~= nil and sa.result.budget.ascendancyTotal == 8,
		"searchAscendancy carries the 8-point ascendancy budget")
	local saAllAsc = #sa.result.nodes > 0
	for _, n in ipairs(sa.result.nodes) do
		local nd = build.spec.nodes[n.id]
		if not (nd and nd.ascendancyName == base) then saAllAsc = false; break end
	end
	check(saAllAsc, "searchAscendancy returns only the selected ascendancy's nodes")

	-- An ascendancy node id (any) to drive the redirect check, plus a reachable
	-- unallocated one to actually allocate.
	local ascAnyId, ascTake
	for _, n in ipairs(sa.result.nodes) do
		ascAnyId = ascAnyId or n.id
		if n.pathDist and not n.alloc and not ascTake then ascTake = n end
	end

	-- setPassive must REJECT an ascendancy node with a redirect to setAscendancy.
	if ascAnyId then
		local mis = call("setPassive", { nodeId = ascAnyId, alloc = true })
		check(not mis.ok and mis.error:find("setAscendancy") ~= nil,
			"setPassive rejects an ascendancy node (redirect to setAscendancy)")
	end
	-- setAscendancy must REJECT a regular node with a redirect to setPassive.
	if targetId then
		local mis2 = call("setAscendancy", { nodeId = targetId, alloc = true })
		check(not mis2.ok and mis2.error:find("setPassive") ~= nil,
			"setAscendancy rejects a regular tree node (redirect to setPassive)")
	end

	if ascTake then
		local ascUsed0 = select(2, build.spec:CountAllocNodes()) or 0
		local sAlloc = call("setAscendancy", { nodeId = ascTake.id, alloc = true, stats = { "Life" } })
		check(sAlloc.ok and sAlloc.result.alloc == true, "setAscendancy allocated ascendancy node " .. tostring(ascTake.id))
		check(sAlloc.result.budget ~= nil and sAlloc.result.budget.ascendancyUsed > ascUsed0,
			"setAscendancy reports the ascendancy point budget moving (ascendancyUsed up)")
		check(sAlloc.result.budget.ascendancyNote ~= nil,
			"ascendancy budget carries the Trial caveat note")
		call("undo", { scope = "tree" }) -- revert the ascendancy allocation
	else
		print("  SKIP: no reachable unallocated ascendancy node to allocate")
	end

	call("setClass", { ascendancy = "" }) -- clear ascendancy back to None for later tests
else
	print("  SKIP: current class has no ascendancy to test searchAscendancy/setAscendancy")
end

-- 5b. jewel sockets (FR-8): discover sockets, allocate one, socket a +Life jewel
--     (effect requires the socket node be allocated), then unsocket + undo.
local jewelRaw = "Rarity: RARE\nMCP Test Jewel\nEmerald\n--------\nItem Level: 80\n--------\n10% increased maximum Life\n"
local js = call("getJewelSockets")
check(js.ok and type(js.result.sockets) == "table" and js.result.count >= 1,
	"getJewelSockets lists the tree's jewel sockets")
local sock
for _, s in ipairs(js.result.sockets) do
	if not s.allocated and s.pathDist then sock = s; break end
end
if sock then
	check(sock.nodeId ~= nil and sock.socketName:find("Jewel") ~= nil, "socket carries a nodeId + slot name")
	check(sock.occupant == false, "an empty socket reports occupant=false")
	-- Allocating the socket auto-allocates its whole path, which itself moves Life;
	-- the post-allocation value is the baseline the jewel adds to / reverts to.
	local alloc = call("setPassive", { nodeId = sock.nodeId, alloc = true, stats = { "Life" } })
	local lifePreSocket = alloc.result.stats.Life
	local jr = call("addItem", { raw = jewelRaw })
	check(jr.ok and jr.result.itemId ~= nil, "addItem added a test jewel")
	local jewelId = jr.result.itemId
	local sj = call("socketJewel", { nodeId = sock.nodeId, itemId = jewelId, stats = { "Life" } })
	check(sj.ok and sj.result.socketed == jewelId, "socketJewel placed the jewel")
	check(sj.result.allocated == true and sj.result.note == nil,
		"socketJewel reports the socket allocated (no inert note)")
	check(build.spec.jewels[sock.nodeId] == jewelId, "spec.jewels reflects the socketed jewel")
	check(sj.result.stats.Life > lifePreSocket, "the +Life jewel raised Life at an allocated socket")
	local js2 = call("getJewelSockets", { onlyAllocated = true })
	local found
	for _, s in ipairs(js2.result.sockets) do if s.nodeId == sock.nodeId then found = s end end
	check(found ~= nil and found.occupant ~= false and found.occupant.itemId == jewelId,
		"getJewelSockets shows the jewel occupant after socketing")
	-- unsocket (omit itemId) -> socket empties, Life returns to baseline
	local us = call("socketJewel", { nodeId = sock.nodeId, stats = { "Life" } })
	check(us.ok and us.result.socketed == false, "socketJewel with no itemId unsockets")
	check((build.spec.jewels[sock.nodeId] or 0) == 0, "spec.jewels cleared after unsocket")
	check(us.result.stats.Life == lifePreSocket, "unsocketing the jewel reverted Life to the pre-socket value")
	-- undo (items scope) restores the jewel in the socket
	local uj = call("undo", { scope = "items" })
	check(uj.ok and build.spec.jewels[sock.nodeId] == jewelId, "undo (items) restored the socketed jewel")
	-- a non-jewel item is rejected (changes nothing)
	local amu = call("addItem", { raw = "Rarity: RARE\nReject Test\nAmber Amulet\n--------\nItem Level: 80\n" })
	local rej = call("socketJewel", { nodeId = sock.nodeId, itemId = amu.result.itemId })
	check(not rej.ok and rej.error:find("not a jewel") ~= nil, "socketJewel rejects a non-jewel item")
	check(build.spec.jewels[sock.nodeId] == jewelId, "rejected socketJewel left the existing jewel in place")
	call("removeItem", { itemId = amu.result.itemId })
	-- clean up: unsocket, remove the jewel, dealloc the socket node
	call("socketJewel", { nodeId = sock.nodeId })
	call("removeItem", { itemId = jewelId })
	call("setPassive", { nodeId = sock.nodeId, alloc = false })
else
	print("  SKIP: no empty reachable jewel socket to test socketJewel")
end
-- inert path: socketing into an UNALLOCATED socket places the jewel but flags it inert
local emptyUnalloc
for _, s in ipairs(call("getJewelSockets").result.sockets) do
	if not s.allocated then emptyUnalloc = s; break end
end
if emptyUnalloc then
	local jr2 = call("addItem", { raw = jewelRaw })
	local sj2 = call("socketJewel", { nodeId = emptyUnalloc.nodeId, itemId = jr2.result.itemId })
	check(sj2.ok and sj2.result.allocated == false and sj2.result.note ~= nil,
		"socketJewel into an unallocated socket flags the jewel inert")
	call("socketJewel", { nodeId = emptyUnalloc.nodeId }) -- unsocket
	call("removeItem", { itemId = jr2.result.itemId })
end
-- error path: a non-socket node id errors clearly
local jBad = call("socketJewel", { nodeId = 999999999 })
check(not jBad.ok and jBad.error:find("no jewel socket") ~= nil, "socketJewel on a non-socket node errors")

-- 6. explainStat: per-stat breakdown for a headline defensive stat
local ex = call("explainStat", { stat = "Life" })
check(ex.ok and ex.result.stat == "Life", "explainStat returns the requested stat")
check(ex.result.value ~= nil, "explainStat returns the stat value")
check((ex.result.lines and #ex.result.lines > 0) or (ex.result.rows and #ex.result.rows > 0)
	or ex.result.note ~= nil, "explainStat returns lines/rows or a clear no-breakdown note")
-- colour codes must be stripped from any returned lines
if ex.result.lines then
	local clean = true
	for _, l in ipairs(ex.result.lines) do if l:find("%^") then clean = false end end
	check(clean, "explainStat lines have colour codes stripped")
end
-- a missing breakdown stat still returns its value with a note (no crash)
local exMiss = call("explainStat", { stat = "DefinitelyNotAStat" })
check(exMiss.ok and exMiss.result.note ~= nil, "explainStat on unknown stat returns a note, not an error")

-- 6b. queryMods (FR-7): discover mod names, then break one down with sources
local qmFind = call("queryMods", { query = "Life" })
check(qmFind.ok and #qmFind.result.matchedNames >= 1, "queryMods lists mod names matching a query")
local hasLife = false
for _, n in ipairs(qmFind.result.matchedNames) do if n.name == "Life" then hasLife = true end end
check(hasLife, "queryMods discovery includes the 'Life' mod name")
local qm = call("queryMods", { mod = "Life" })
check(qm.ok and type(qm.result.modifiers) == "table" and qm.result.count >= 1,
	"queryMods returns the contributing modifiers for 'Life'")
check(type(qm.result.sumBase) == "number" and type(qm.result.moreMultiplier) == "number",
	"queryMods returns summed BASE + MORE multiplier")
check(qm.result.modifiers[1].type ~= nil and qm.result.modifiers[1].source ~= nil,
	"queryMods modifiers carry a type + source")
local qmBad = call("queryMods", { mod = "NotARealModName" })
check(not qmBad.ok and qmBad.error:find("no modifiers named") ~= nil, "queryMods on an unknown mod errors clearly")

-- 7. lifecycle: save-as into a temp dir, then plain save; confirm a file lands
local tmpDir = (os.getenv("TMPDIR") or "/tmp") .. "/pob_mcp_test_" .. tostring(os.time()) .. "/"
os.execute("mkdir -p '" .. tmpDir .. "'")
main.buildPath = tmpDir
local sa = call("lifecycle", { action = "saveAs", name = "MCP Test Build" })
check(sa.ok and sa.result.saved == true, "lifecycle saveAs reports saved")
check(sa.result.buildName == "MCP Test Build", "saveAs set the build name")
check(sa.result.path == tmpDir .. "MCP Test Build.xml", "saveAs resolved path under buildPath")
local f = io.open(tmpDir .. "MCP Test Build.xml", "r")
check(f ~= nil and f:read("*a"):match("PathOfBuilding2"), "saveAs wrote a valid build XML file")
if f then f:close() end
-- plain save now reuses the dbFileName set by saveAs (no name needed)
local sv = call("lifecycle", { action = "save" })
check(sv.ok and sv.result.saved == true, "lifecycle save (reusing dbFileName) succeeds")
-- save on a build that was never saved is a clear error, not a blocking dialog
build.dbFileName = nil
local svErr = call("lifecycle", { action = "save" })
check(not svErr.ok and svErr.error:match("never been saved"), "save on unsaved build errors cleanly")
build.dbFileName = tmpDir .. "MCP Test Build.xml" -- restore for cleanliness

-- 8. skills: add a gem (creates a group if needed), tweak it, remove it
local sg = call("addGem", { name = "Fireball" })
check(sg.ok and sg.result.name == "Fireball", "addGem resolved the gem to its real name")
check(sg.result.gemIndex >= 1, "addGem reports a gem index")
local addedGroup, addedIndex = sg.result.group, sg.result.gemIndex
local addedGem = build.skillsTab.socketGroupList[addedGroup].gemList[addedIndex]
check(addedGem ~= nil and addedGem.gemId ~= nil, "added gem is in the live gemList with a gemId")
-- REGRESSION GUARD: the bridge-added gem MUST carry its nameSpec, else the live GUI
-- editor prunes it from the displayed group (deleteGem on a blank/unmatched buffer).
check(addedGem.nameSpec == "Fireball", "added gem has its nameSpec set (not blank -> won't be GUI-pruned)")
-- mutator returns a ground-truth gem list + derived flag (so the caller verifies, not guesses)
check(type(sg.result.gems) == "table" and sg.result.gems[addedIndex]
	and sg.result.gems[addedIndex].name == "Fireball", "addGem returns the group's gem list with real names")
check(sg.result.derived == false, "a hand-socketed group is reported not-derived")

-- add a support gem to the same group
local sup = call("addGem", { group = addedGroup, name = "Fire Penetration I" })
check(sup.ok and sup.result.name == "Fire Penetration I", "addGem added a named support gem to the group")

-- set the gem's level/quality
local setg = call("setGem", { group = addedGroup, index = addedIndex, level = 10, quality = 15 })
check(setg.ok and setg.result.level == 10 and setg.result.quality == 15, "setGem applied level/quality")
check(build.skillsTab.socketGroupList[addedGroup].gemList[addedIndex].level == 10, "live gem level updated")

-- make it the main skill, then undo (skills scope) reverts the last change
local sm = call("setMainSkill", { group = addedGroup })
check(sm.ok and sm.result.mainSocketGroup == addedGroup, "setMainSkill set the main socket group")

-- 8b. getSkills: read back the groups + gems we just built (so gem tools aren't a guess)
local gk = call("getSkills")
check(gk.ok and gk.result.count >= 1, "getSkills lists socket groups")
local gkGroup
for _, g in ipairs(gk.result.groups) do if g.index == addedGroup then gkGroup = g end end
check(gkGroup ~= nil and gkGroup.isMain == true, "getSkills marks the main group we just set")
check(gkGroup ~= nil and #gkGroup.gems >= 2, "getSkills returns the group's gems")
check(gkGroup ~= nil and gkGroup.gems[addedIndex] ~= nil and gkGroup.gems[addedIndex].level == 10,
	"getSkills reports the gem's index + level we set")
check(gkGroup ~= nil and gkGroup.gems[addedIndex].name == "Fireball",
	"getSkills reports the gem's real name (nameSpec populated)")
check(gkGroup ~= nil and gkGroup.derived == false,
	"getSkills flags whether a group is item/node-derived (source)")

local groupLenBefore = #build.skillsTab.socketGroupList[addedGroup].gemList
local rem = call("removeGem", { group = addedGroup, index = addedIndex })
check(rem.ok and rem.result.remaining == groupLenBefore - 1, "removeGem shrank the gemList")
local uSkill = call("undo", { scope = "skills" })
check(uSkill.ok and #build.skillsTab.socketGroupList[addedGroup].gemList == groupLenBefore,
	"undo (skills scope) restored the removed gem")

-- unrecognised gem name errors cleanly
local badGem = call("addGem", { name = "Zzzznotagem" })
check(not badGem.ok and badGem.error ~= nil, "addGem on an unknown gem returns an error")

-- 9. items: add + equip a rare amulet with a ranged Life roll, adjust it, remove it
local amuletRaw = [[
Rarity: RARE
Test Amulet
Amber Amulet
--------
Requirements:
Level: 1
--------
Item Level: 80
--------
{range:0.5}+(20-40) to maximum Life
]]
local lifeBefore = build.calcsTab.mainOutput.Life
local ai = call("addItem", { raw = amuletRaw, equip = true })
check(ai.ok and ai.result.itemId ~= nil, "addItem parsed and added the amulet")
check(ai.result.equippedSlot == "Amulet", "addItem equipped to the Amulet slot")
check(ai.result.stats.Life > lifeBefore, "equipping the +Life amulet raised Life")
local amuletId = ai.result.itemId
local lifeAtMid = ai.result.stats.Life

-- getItems: DISCOVER the equipped amulet + its ranged roll (the Stage "can't read
-- items" fix) — find the item id and the rollable mod's modIndex without guessing.
local gi = call("getItems")
check(gi.ok and gi.result.equippedCount >= 1, "getItems lists equipped items")
local amulet
for _, it in ipairs(gi.result.items) do if it.itemId == amuletId then amulet = it end end
check(amulet ~= nil and amulet.slot == "Amulet", "getItems found the equipped amulet by id + slot")
if amulet then
	local mod = amulet.explicitMods[1]
	check(mod ~= nil and mod.ranged == true, "getItems flags the Life mod as a ranged roll")
	check(mod.modIndex == 1 and mod.min == 20 and mod.max == 40,
		"getItems reports modIndex + min/max for the ranged roll (setItemRoll target)")
	check(type(amulet.raw) == "string" and amulet.raw:find("maximum Life") ~= nil,
		"getItems returns the item's raw text")
end
local giSlot = call("getItems", { slot = "Amulet" })
check(giSlot.ok and giSlot.result.equippedCount == 1, "getItems with slot filter returns just that slot")
local giBad = call("getItems", { slot = "NotARealSlot" })
check(not giBad.ok and giBad.error:find("no such equipment slot") ~= nil, "getItems on a bad slot errors")

-- adjust the Life roll to max (range=1) -> Life should rise above the 0.5 roll
local roll = call("setItemRoll", { itemId = amuletId, modIndex = 1, range = 1 })
check(roll.ok and roll.result.range == 1, "setItemRoll set range to 1.0")
check(roll.result.stats.Life > lifeAtMid, "maxing the Life roll raised Life further")

-- a non-ranged / bad index errors cleanly
local badRoll = call("setItemRoll", { itemId = amuletId, modIndex = 99, range = 0.5 })
check(not badRoll.ok and badRoll.error:match("no explicit mod"), "setItemRoll on a bad index errors")

-- 9b. replaceItem: edit in place — ADD a Cold Resistance line (the "add cold-res to
-- a ring/amulet" case) by swapping the raw text. Slot must be preserved.
local coldBefore = roll.result.stats.ColdResist
local newRaw = [[
Rarity: RARE
Test Amulet
Amber Amulet
--------
Requirements:
Level: 1
--------
Item Level: 80
--------
+(20-40) to maximum Life
+45% to Cold Resistance
]]
local rep = call("replaceItem", { itemId = amuletId, raw = newRaw, stats = { "ColdResist" } })
check(rep.ok and rep.result.itemId ~= nil and rep.result.itemId ~= amuletId,
	"replaceItem swapped the item for a new id")
local keptAmuletSlot = false
for _, s in ipairs(rep.result.slots or {}) do if s == "Amulet" then keptAmuletSlot = true end end
check(keptAmuletSlot, "replaceItem preserved the Amulet slot")
check(rep.result.stats.ColdResist > coldBefore, "replaceItem added Cold Resistance (stat rose)")
-- the replacement is discoverable, with the new cold-res line
local giNew = call("getItems", { slot = "Amulet" })
local hasCold = false
for _, m in ipairs(giNew.result.items[1] and giNew.result.items[1].explicitMods or {}) do
	if m.line and m.line:find("Cold Resistance") then hasCold = true end
end
check(hasCold, "getItems shows the added Cold Resistance mod on the replacement")
-- an incompatible base for the occupied slot is rejected, changing nothing
local badRep = call("replaceItem", { itemId = rep.result.itemId, raw = "Rarity: NORMAL\nIron Greaves\nIron Greaves\n" })
check(not badRep.ok and badRep.error:find("not valid for slot") ~= nil,
	"replaceItem rejects an incompatible base for the slot")
-- undo restores the original amulet (same id) so the rest of the test continues
local uRep = call("undo", { scope = "items" })
check(uRep.ok and build.itemsTab.items[amuletId] ~= nil, "undo restored the original amulet after replace")

-- remove the amulet -> Life returns to baseline
local ri = call("removeItem", { itemId = amuletId })
check(ri.ok and ri.result.stats.Life == lifeBefore, "removeItem reverted Life to baseline")

-- undo (items scope) brings the amulet back
local uItem = call("undo", { scope = "items" })
check(uItem.ok and uItem.result.scope == "items", "undo items scope ok")
check(build.itemsTab.items[amuletId] ~= nil, "undo restored the removed amulet")

-- 5. unknown method yields a clean error response (not a crash)
local e = call("bogusMethod")
check(not e.ok and e.error:match("unknown method"), "unknown method returns an error response")

-- 6. exportXml: snapshot the live build to XML in-memory (the search primitive)
local ex = call("exportXml")
check(ex.ok and type(ex.result.xml) == "string", "exportXml returns XML text")
check(ex.result.xml:match("PathOfBuilding2"), "exportXml XML has the PoB2 root element")
local snapshotXml = ex.result.xml

-- 7. setClass: change class/ascendancy/level on the live build (FR-8)
local firstClass = build.spec.curClassName
local sc = call("setClass", { className = "Witch", level = 80 })
check(sc.ok and sc.result.className == "Witch", "setClass switched to Witch")
check(sc.result.level == 80, "setClass set level 80")
check(build.spec.curClassName == "Witch", "live spec reflects the class change")
-- an invalid ascendancy for the class errors cleanly
local badAsc = call("setClass", { ascendancy = "NotARealAscendancy" })
check(not badAsc.ok and badAsc.error:match("ascendancy"), "setClass rejects an invalid ascendancy")

-- 8. lifecycle new: replace the build with a fresh one (FR-15/FR-16)
local nb = call("lifecycle", { action = "new", name = "Phase3 Test", className = "Ranger", level = 12 })
check(nb.ok and nb.result.action == "new", "lifecycle new succeeded")
check(nb.result.className == "Ranger" and nb.result.level == 12, "new build has the requested class/level")
check(build.buildName == "Phase3 Test", "live build name updated after new")
check(nb.result.stats and nb.result.stats.Life ~= nil, "new build computes stats (Life present)")
-- the bridge's build reference must still be valid after the in-place re-init
check(Bridge.build == build, "bridge build reference survives new-build re-init")

-- 9. applyChangeSet: replay an ordered op list (winner-replay path, FR-13)
local cs = call("applyChangeSet", { ops = {
	{ method = "setConfig", params = { var = "conditionFullLife", value = true } },
	{ method = "setClass", params = { level = 90 } },
} })
check(cs.ok and cs.result.applied == 2, "applyChangeSet applied both ops")
check(build.characterLevel == 90, "applyChangeSet's setClass op took effect")
-- a bad op errors with its index
local badCs = call("applyChangeSet", { ops = { { method = "nopeNotAMethod" } } })
check(not badCs.ok and badCs.error:match("unknown method"), "applyChangeSet reports an unknown op method")

-- 10. tree version switching (FR-8): discover specs + versions, convert (keeping
--     the old tree), then revert by switching back to the previous spec.
local ts = call("getTreeSpecs")
check(ts.ok and type(ts.result.specs) == "table" and ts.result.specCount >= 1,
	"getTreeSpecs lists the build's specs")
check(type(ts.result.availableVersions) == "table" and #ts.result.availableVersions >= 1,
	"getTreeSpecs lists available tree versions")
check(ts.result.latestTreeVersion ~= nil, "getTreeSpecs reports the latest tree version")
local activeVersion
for _, s in ipairs(ts.result.specs) do if s.isActive then activeVersion = s.treeVersion end end
check(activeVersion ~= nil, "getTreeSpecs flags exactly one active spec")
local latestFlagged = false
for _, v in ipairs(ts.result.availableVersions) do
	if v.version == ts.result.latestTreeVersion then check(v.isLatest == true, "availableVersions flags latest"); latestFlagged = true end
end
check(latestFlagged, "availableVersions includes the latest version")

-- pick a target version that differs from the active one
local targetVersion
for _, v in ipairs(ts.result.availableVersions) do
	if v.version ~= activeVersion then targetVersion = v.version; break end
end
if targetVersion then
	-- Allocate a few real nodes first so the revert check actually proves the old
	-- tree's allocations are restored (not a trivial 0 == 0).
	build.spec:BuildAllDependsAndPaths()
	local seeded = 0
	for _, node in pairs(build.spec.nodes) do
		if not node.alloc and node.pathDist and node.pathDist < 1000 and node.type ~= "ClassStart"
			and not node.ascendancyName and node.type ~= "Socket" then
			build.spec:AllocNode(node)
			seeded = seeded + 1
			if seeded >= 3 then break end
		end
	end
	local specsBefore = ts.result.specCount
	local allocBefore = build.spec:CountAllocNodes()
	check(allocBefore >= 1, "seeded the active tree with allocations before conversion")
	local prevVersion = activeVersion
	local conv = call("setTreeVersion", { version = targetVersion, stats = { "Life" } })
	check(conv.ok and conv.result.version == targetVersion, "setTreeVersion converted to the target version")
	check(conv.result.previousVersion == prevVersion, "setTreeVersion reports the previous version")
	check(conv.result.keptOld == true and type(conv.result.previousSpec) == "number",
		"setTreeVersion kept the old tree as a revertible spec")
	check(build.spec.treeVersion == targetVersion, "live active spec is now the target version")
	check(build.treeTab.specList[conv.result.previousSpec].treeVersion == prevVersion,
		"the previous tree is retained at previousSpec with its original version")
	check(#build.treeTab.specList == specsBefore + 1, "keepOld added a new spec (old one retained)")
	check(type(conv.result.deallocatedNodes) == "table"
		and conv.result.deallocatedCount == #conv.result.deallocatedNodes,
		"setTreeVersion reports the de-allocated node diff")
	check(conv.result.stats ~= nil and conv.result.stats.Life ~= nil, "setTreeVersion returns refreshed stats")
	-- a bare gui_undo must NOT silently revert the conversion (scope was cleared)
	local undoAfterConv = call("undo")
	check(not undoAfterConv.ok and undoAfterConv.error:find("requires a 'scope'") ~= nil,
		"a bare undo after conversion errors (conversion isn't on a per-tab undo stack)")

	-- revert: switch back to the previous spec, the original tree returns intact
	local sel = call("selectSpec", { spec = conv.result.previousSpec, stats = { "Life" } })
	check(sel.ok and build.spec.treeVersion == prevVersion, "selectSpec switched back to the previous tree version")
	check(build.spec:CountAllocNodes() == allocBefore,
		"the reverted tree has all its original allocations (" .. allocBefore .. ")")
	check(build.treeTab.activeSpec == conv.result.previousSpec, "activeSpec follows selectSpec")

	-- getTreeSpecs now shows both specs with the right active flag
	local ts2 = call("getTreeSpecs")
	check(ts2.result.specCount == specsBefore + 1, "getTreeSpecs sees both specs after convert+revert")
	local activeCount = 0
	for _, s in ipairs(ts2.result.specs) do if s.isActive then activeCount = activeCount + 1 end end
	check(activeCount == 1, "exactly one spec is active after selectSpec")

	-- error paths
	local badVer = call("setTreeVersion", { version = "9_9" })
	check(not badVer.ok and badVer.error:find("known 'version'") ~= nil, "setTreeVersion rejects an unknown version")
	local sameVer = call("setTreeVersion", { version = prevVersion })
	check(not sameVer.ok and sameVer.error:find("already on version") ~= nil, "setTreeVersion rejects the current version")
	local badSpec = call("selectSpec", { spec = 999 })
	check(not badSpec.ok and badSpec.error:find("valid 1%-based") ~= nil, "selectSpec rejects an out-of-range index")
else
	print("  SKIP: only one tree version available; can't test setTreeVersion")
end

-- 11. item browser (FR-9): search PoB's unique DB, then add a found unique BY NAME
--     (the real mods land — no pasting), confirm + clean up. Then error paths.
local siAll = call("searchItems", { type = "Amulet", limit = 50 })
check(siAll.ok and type(siAll.result.items) == "table", "searchItems returns a unique list")
check(siAll.result.total >= 1, "searchItems found amulet uniques in the DB")
local dbAmulet
for _, it in ipairs(siAll.result.items) do
	if it.itemType == "Amulet" and it.name then dbAmulet = it; break end
end
if dbAmulet then
	check(dbAmulet.title ~= nil and dbAmulet.baseName ~= nil, "searchItems item carries title + baseName")
	check(type(dbAmulet.explicitMods) == "table", "searchItems returns the unique's mod lines by default")
	-- a query narrows the set and matches mod text too
	local siQ = call("searchItems", { query = dbAmulet.title, type = "Amulet" })
	local foundByName = false
	for _, it in ipairs(siQ.result.items) do if it.name == dbAmulet.name then foundByName = true end end
	check(siQ.ok and foundByName, "searchItems query matches a unique by its title")
	check(siQ.result.total <= siAll.result.total, "a query narrows the result set")
	-- includeMods=false omits the mod lines
	local siNoMods = call("searchItems", { type = "Amulet", includeMods = false, limit = 1 })
	check(siNoMods.ok and siNoMods.result.items[1] and siNoMods.result.items[1].explicitMods == nil,
		"searchItems includeMods=false omits mod lines")

	-- ADD the unique BY NAME (DB lookup), equipped to the Amulet slot
	local lifeBeforeUnique = build.calcsTab.mainOutput.Life
	local au = call("addItem", { name = dbAmulet.name, equip = true, slot = "Amulet", stats = { "Life" } })
	check(au.ok and au.result.itemId ~= nil, "addItem added a unique by name from the DB")
	check(au.result.fromDatabase == dbAmulet.name, "addItem reports it resolved the unique from the database")
	check(au.result.equippedSlot == "Amulet", "addItem equipped the unique to the Amulet slot")
	local addedUnique = build.itemsTab.items[au.result.itemId]
	check(addedUnique ~= nil and addedUnique.rarity == "UNIQUE" and #addedUnique.explicitModLines >= 1,
		"the added unique has real explicit mods (not a blank item)")
	check(addedUnique.title == dbAmulet.title, "the added item matches the requested unique")
	-- clean up so the rest of the suite/build is unaffected
	call("removeItem", { itemId = au.result.itemId, stats = { "Life" } })
	check(build.calcsTab.mainOutput.Life == lifeBeforeUnique, "removing the unique restored the prior Life")

	-- add by name WITHOUT equipping (also exercise a bare-title lookup)
	local au2 = call("addItem", { name = dbAmulet.title })
	check(au2.ok and au2.result.fromDatabase ~= false and au2.result.equippedSlot == false,
		"addItem by bare title resolves the unique and leaves it unequipped")
	call("removeItem", { itemId = au2.result.itemId })
else
	print("  SKIP: no amulet unique in the DB to test the item browser")
end
-- error paths: unknown unique, and the original raw path still works + still required
local missing = call("addItem", { name = "Zzz Definitely Not A Real Unique" })
check(not missing.ok and missing.error:find("no unique named") ~= nil,
	"addItem on an unknown unique errors clearly (points at searchItems)")
local neither = call("addItem", {})
check(not neither.ok and neither.error:find("raw") ~= nil and neither.error:find("name") ~= nil,
	"addItem with neither raw nor name errors clearly")

-- 12. gem browser (FR-10): search PoB's gem DB, confirm descriptions + tier handling,
--     then add a found gem BY NAME (closes the discover-before-mutate loop for gems).
local sgAll = call("searchGems", { limit = 5 })
check(sgAll.ok and type(sgAll.result.gems) == "table" and sgAll.result.total > 100,
	"searchGems lists the gem database")
check(sgAll.result.gems[1] and sgAll.result.gems[1].name ~= nil and sgAll.result.gems[1].description ~= nil,
	"searchGems returns name + description by default")
-- support filter returns only supports; active filter only actives
local sgSup = call("searchGems", { support = true, limit = 200 })
local allSup = sgSup.ok
for _, g in ipairs(sgSup.result.gems) do if not g.support then allSup = false end end
check(allSup and sgSup.result.total >= 1, "searchGems support=true returns only support gems")
local sgAct = call("searchGems", { support = false, limit = 5 })
local allAct = sgAct.ok
for _, g in ipairs(sgAct.result.gems) do if g.support then allAct = false end end
check(allAct, "searchGems support=false returns only active skills")
-- a family query surfaces tiered support gems by their exact names
local sgPen = call("searchGems", { query = "Fire Penetration", support = true })
local penNames = {}
for _, g in ipairs(sgPen.result.gems) do penNames[g.name] = true; check(g.gemFamily ~= nil, "support gem carries a gemFamily") end
check(sgPen.ok and penNames["Fire Penetration I"], "searchGems finds tiered support gems by family (Fire Penetration I)")
-- type filter narrows by tag/gemType; includeDescription=false omits descriptions
local sgCold = call("searchGems", { type = "Cold", limit = 50 })
check(sgCold.ok and sgCold.result.returned >= 1, "searchGems type filter returns matches")
local sgNoDesc = call("searchGems", { limit = 1, includeDescription = false })
check(sgNoDesc.ok and sgNoDesc.result.gems[1] and sgNoDesc.result.gems[1].description == nil,
	"searchGems includeDescription=false omits descriptions")

-- the loop: search → add the found gem by its exact name
local sgIce = call("searchGems", { query = "Ice Nova", support = false })
local iceName
for _, g in ipairs(sgIce.result.gems) do if g.name == "Ice Nova" then iceName = g.name end end
if iceName then
	local groupsBefore = #build.skillsTab.socketGroupList
	local addg = call("addGem", { name = iceName })
	check(addg.ok and addg.result.name ~= nil, "addGem added the gem found via searchGems by name")
	check(#build.skillsTab.socketGroupList >= groupsBefore, "addGem placed the searched gem in a group")
	call("removeGem", { group = addg.result.group, index = addg.result.gemIndex })
else
	print("  SKIP: 'Ice Nova' not in gem DB this version")
end

-- 13. ISSUES.md follow-ups: stat-key discovery (B4/M5), set_gem clamp notice (B2),
--     blank-unique guard (B5), socket-group create/set + FullDPS toggle (B3/M2), items
--     slot listing (P3).

-- B4: unknown stat keys are surfaced, not silently dropped
local bUnknown = call("getBuild", { stats = { "Life", "TotallyFakeStatXYZ" } })
check(bUnknown.ok and bUnknown.result.stats.Life ~= nil, "getBuild returns the valid stat")
check(type(bUnknown.result.unknownStats) == "table" and bUnknown.result.unknownStats[1] == "TotallyFakeStatXYZ",
	"getBuild reports unknown stat keys in unknownStats (B4)")
local bKnown = call("getBuild", { stats = { "Life" } })
check(bKnown.result.unknownStats == nil, "getBuild omits unknownStats when all keys are valid")

-- M5: stat-key discovery
local sk = call("getStatKeys", { query = "resist" })
check(sk.ok and sk.result.total >= 1 and type(sk.result.keys) == "table", "getStatKeys lists matching output keys")
local hasFireResist = false
for _, e in ipairs(sk.result.keys) do if e.key == "FireResist" then hasFireResist = true end end
check(hasFireResist, "getStatKeys finds a real key (FireResist) by query")
check(type(sk.result.defaultStats) == "table", "getStatKeys returns the curated default set")

-- M2: create a fresh socket group, add a gem into it, verify
local cg = call("createSocketGroup", { label = "MCP Test Link" })
check(cg.ok and type(cg.result.group) == "number" and #cg.result.gems == 0,
	"createSocketGroup returns a new empty group index")
local newGroupIdx = cg.result.group
local addToNew = call("addGem", { group = newGroupIdx, name = "Fireball" })
check(addToNew.ok and addToNew.result.name == "Fireball" and #addToNew.result.gems == 1,
	"addGem into the created group persists (gems echo confirms)")
-- addGem newGroup=true makes another fresh group
local groupsBefore = #build.skillsTab.socketGroupList
local addNG = call("addGem", { newGroup = true, name = "Ice Nova" })
check(addNG.ok and #build.skillsTab.socketGroupList == groupsBefore + 1 and addNG.result.name == "Ice Nova",
	"addGem newGroup=true starts a fresh group")

-- B3: FullDPS is controllable via includeInFullDPS on a group
call("setMainSkill", { group = newGroupIdx })
local incOn = call("setSocketGroup", { group = newGroupIdx, includeInFullDPS = true, stats = { "FullDPS" } })
check(incOn.ok and incOn.result.includeInFullDPS == true, "setSocketGroup enabled includeInFullDPS")
check(incOn.result.stats.FullDPS ~= nil and incOn.result.stats.FullDPS > 0,
	"FullDPS is non-zero once the main group is included (B3)")
local incOff = call("setSocketGroup", { group = newGroupIdx, includeInFullDPS = false, stats = { "FullDPS" } })
check(incOff.ok and incOff.result.includeInFullDPS == false,
	"setSocketGroup can turn includeInFullDPS back off (the toggle that gates FullDPS — explains B3)")
-- clean up the test groups
call("removeGem", { group = newGroupIdx, index = 1 })

-- B2: set_gem clamp is reported, not silently swallowed. Build a group with a tiered
-- support (Fire Penetration I, natural max level 1) and try to set it to 20.
local cg2 = call("createSocketGroup", {})
local g2 = cg2.result.group
call("addGem", { group = g2, name = "Fireball" })            -- an active to host the support
local penAdd = call("addGem", { group = g2, name = "Fire Penetration I" })
local penIdx = penAdd.result.gemIndex
local clamp = call("setGem", { group = g2, index = penIdx, level = 20 })
check(clamp.ok and clamp.result.level == 1 and clamp.result.levelClamped == true,
	"setGem reports levelClamped when the engine caps the level (B2)")
check(type(clamp.result.note) == "string" and clamp.result.note:find("max level") ~= nil,
	"setGem note explains the clamp")
-- a valid level change is NOT flagged as clamped
local okLevel = call("setGem", { group = g2, index = 1, level = 5 })
check(okLevel.ok and okLevel.result.level == 5 and okLevel.result.levelClamped == false,
	"a within-range level change is applied and not flagged clamped")

-- B5: a bare-raw UNIQUE with no mods is refused with guidance toward name=
local blank = call("addItem", { raw = "Rarity: UNIQUE\nAstramentis\nStellar Amulet" })
check(not blank.ok and blank.error:find("name=") ~= nil and blank.error:find("BLANK") ~= nil,
	"addItem refuses a blank known-unique raw and points at the name= path (B5)")
-- a NORMAL bare item is still fine (no guard)
local normalItem = call("addItem", { raw = "Rarity: NORMAL\nPlain Test\nStellar Amulet" })
check(normalItem.ok, "addItem still accepts a normal (non-unique) bare item")
if normalItem.ok then call("removeItem", { itemId = normalItem.result.itemId }) end

-- P3: getItems exposes valid slot names + (opt-in) empty slots
local gi = call("getItems", { includeEmpty = true })
check(gi.ok and type(gi.result.validSlots) == "table" and #gi.result.validSlots > 5,
	"getItems returns the list of valid equipment slot names (P3)")
local hasAmuletSlot = false
for _, s in ipairs(gi.result.validSlots) do if s == "Amulet" then hasAmuletSlot = true end end
check(hasAmuletSlot, "validSlots includes a known slot name (Amulet)")
check(type(gi.result.emptySlots) == "table", "getItems returns emptySlots when includeEmpty=true")
local giNoEmpty = call("getItems")
check(giNoEmpty.result.emptySlots == nil, "getItems omits emptySlots by default")

-- 14. SUMMARY.md follow-ups: config pagination + modifiedOnly + isDefault (#1/#9),
--     passive point budget (#2), safe deallocation dryRun/maxRemoved + leaf info (#3),
--     getSkills gem kind/tags (#5).

-- #1/#9: getConfig is paginated, flags isDefault, and supports modifiedOnly
local cfgAll = call("getConfig", {})
check(cfgAll.ok and type(cfgAll.result.total) == "number" and cfgAll.result.total > cfgAll.result.count,
	"getConfig paginates (count < total) instead of dumping everything")
check(cfgAll.result.count <= 60, "getConfig honours a default page limit")
check(cfgAll.result.options[1] and cfgAll.result.options[1].isDefault ~= nil,
	"getConfig marks each option isDefault (#9)")
-- set one option, then modifiedOnly should surface it
call("setConfig", { var = "conditionFullLife", value = true })
local cfgMod = call("getConfig", { modifiedOnly = true })
local foundMod = false
for _, o in ipairs(cfgMod.result.options) do
	check(o.isDefault == false, "modifiedOnly returns only non-default options")
	if o.var == "conditionFullLife" then foundMod = true end
end
check(cfgMod.ok and foundMod, "getConfig modifiedOnly surfaces a user-changed option (#1/#9)")
call("undo", { scope = "config" }) -- revert the toggle
local cfgPage = call("getConfig", { offset = 0, limit = 5 })
check(cfgPage.ok and cfgPage.result.count == 5 and cfgPage.result.hasMore == true,
	"getConfig respects offset/limit and flags hasMore")

-- #2: passive point budget in getBuild + getTreeSpecs
local pb = call("getBuild")
check(pb.ok and type(pb.result.points) == "table", "getBuild returns a points budget (#2)")
check(type(pb.result.points.pointsUsed) == "number" and type(pb.result.points.pointsTotal) == "number"
	and pb.result.points.pointsRemaining == pb.result.points.pointsTotal - pb.result.points.pointsUsed,
	"points budget is self-consistent (remaining = total - used)")
check(pb.result.points.ascendancyTotal == 8 and type(pb.result.points.ascendancyUsed) == "number",
	"points budget includes ascendancy used/total")
-- pointsUsed must NET OUT weapon-set passives (allocMode 1/2), mirroring PoB's own
-- EstimatePlayerProgress (normalPassives = used - min(ws1, ws2)); otherwise a legal tree
-- with weapon-set points reads as phantom-overspent (the gui_get_build -19 bug).
local rawUsed, _, _, _, ws1, ws2 = build.spec:CountAllocNodes()
local expectedNormal = rawUsed - math.min(ws1 or 0, ws2 or 0)
check(pb.result.points.pointsUsed == expectedNormal,
	"pointsUsed nets out weapon-set passives (= raw used - min(ws1, ws2))")
check(type(pb.result.points.weaponSet) == "table"
	and pb.result.points.weaponSet.set1 == (ws1 or 0)
	and pb.result.points.weaponSet.set2 == (ws2 or 0)
	and type(pb.result.points.weaponSet.max) == "number",
	"points budget reports weapon-set usage (set1/set2/max) separately")
local tsp = call("getTreeSpecs")
check(tsp.ok and type(tsp.result.points) == "table", "getTreeSpecs also returns the points budget")

-- #3: safe deallocation. Allocate a multi-node path, then dry-run a deallocation of a
-- connector to PREVIEW the cascade, and confirm maxRemoved blocks an over-large refund.
local farNode
for _, n in ipairs(call("searchPassives", { query = "", maxDist = 30, limit = 400 }).result.nodes) do
	if n.pathDist and n.pathDist >= 2 then farNode = n; break end
end
if farNode then
	local taken = call("setPassive", { nodeId = farNode.id, alloc = true })
	-- search the allocated set for a connector (dependentCount > 0) and a leaf
	local sAlloc = call("searchPassives", { query = "", includeAllocated = true, maxDist = 0, limit = 300 })
	local connector, leaf
	for _, n in ipairs(sAlloc.result.nodes) do
		if n.alloc and n.dependentCount and n.dependentCount >= 1 and not connector then connector = n end
		if n.alloc and n.isLeaf and not leaf then leaf = n end
	end
	check(sAlloc.ok, "searchPassives includeAllocated returns allocated nodes")
	check(leaf ~= nil and leaf.isLeaf == true, "searchPassives flags an allocated leaf (isLeaf, #3)")
	if connector then
		check(type(connector.dependentCount) == "number" and connector.dependentCount >= 1,
			"searchPassives reports dependentCount for a connector node")
		-- dry run: preview the cascade WITHOUT applying
		local cntBefore = build.spec:CountAllocNodes()
		local dry = call("setPassive", { nodeId = connector.id, alloc = false, dryRun = true })
		check(dry.ok and dry.result.dryRun == true and dry.result.changedCount >= 2,
			"setPassive dryRun previews the dealloc cascade (#3)")
		check(build.spec:CountAllocNodes() == cntBefore, "dryRun changed nothing")
		-- maxRemoved guard refuses the over-large refund
		local guarded = call("setPassive", { nodeId = connector.id, alloc = false, maxRemoved = 1 })
		check(not guarded.ok and guarded.error:find("maxRemoved") ~= nil, "maxRemoved guard blocks a cascading refund (#3)")
		check(build.spec:CountAllocNodes() == cntBefore, "the rejected refund changed nothing")
	end
	call("undo", { scope = "tree" }) -- restore baseline
else
	print("  SKIP: no node >= 3 points away to test dealloc safety")
end

-- #5: getSkills marks active-vs-support + tags per gem
local skAdd = call("addGem", { newGroup = true, name = "Fireball" })
local skGroup = skAdd.result.group
call("addGem", { group = skGroup, name = "Fire Penetration I" })
local gks = call("getSkills")
local grp
for _, g in ipairs(gks.result.groups) do if g.index == skGroup then grp = g end end
check(grp ~= nil and grp.gems[1].support == false and type(grp.gems[1].tags) == "string",
	"getSkills marks an active skill (support=false) with tags (#5)")
check(grp ~= nil and grp.gems[2] and grp.gems[2].support == true,
	"getSkills marks a support gem (support=true) (#5)")
-- clean up the test group's gems
call("removeGem", { group = skGroup, index = 2 })
call("removeGem", { group = skGroup, index = 1 })

-- 15. M1: gui_explain_skill — per-skill damage/ailment breakdown (read-only).
-- Set up a main skill so there's something to explain.
call("addGem", { newGroup = true, name = "Fireball" })
local mainGroupForSkill = #build.skillsTab.socketGroupList
call("setMainSkill", { group = mainGroupForSkill })
local es = call("explainSkill")
check(es.ok and es.result.name ~= nil, "explainSkill returns the main skill's name")
check(es.result.isMain == true and es.result.group == mainGroupForSkill, "explainSkill defaults to the main group")
check(type(es.result.hit) == "table" and type(es.result.hit.byType) == "table",
	"explainSkill returns hit damage broken down by damage type")
check(type(es.result.crit) == "table" and type(es.result.dps) == "table",
	"explainSkill returns crit + dps sections")
check(type(es.result.ailments) == "table", "explainSkill returns an ailments map")
check(type(es.result.tags) == "string" and es.result.tags:find("Fire") ~= nil,
	"explainSkill returns the skill's tags (Fireball is tagged Fire)")
-- Fireball is a fire spell → expect Fire hit damage present
check(es.result.hit.byType.Fire ~= nil and (es.result.hit.byType.Fire.average or 0) > 0,
	"explainSkill shows Fire hit damage for Fireball")
-- READ-ONLY for a non-main group: explaining another group must not change the live main skill
local prevMain = build.mainSocketGroup
local lifeBefore = build.calcsTab.mainOutput.Life
local otherGroup = (mainGroupForSkill > 1) and 1 or mainGroupForSkill
if otherGroup ~= mainGroupForSkill and build.skillsTab.socketGroupList[otherGroup] then
	local es2 = call("explainSkill", { group = otherGroup })
	check(es2.ok and es2.result.group == otherGroup and es2.result.isMain == false,
		"explainSkill reads a non-main group")
	check(build.mainSocketGroup == prevMain and build.calcsTab.mainOutput.Life == lifeBefore,
		"explainSkill on a non-main group left the live build's main skill unchanged (read-only)")
end
-- error path: a bad group index
local esBad = call("explainSkill", { group = 9999 })
check(not esBad.ok and esBad.error:find("no socket group") ~= nil, "explainSkill errors on a bad group index")
-- clean up the test group
call("removeGem", { group = mainGroupForSkill, index = 1 })

-- 16. #4 atomic socket-group build + #3 tag-compatible support search.
-- Build a whole link (active + supports) in ONE call.
local atomic = call("createSocketGroup", { label = "Atomic Link",
	gems = { "Fireball", "Fire Penetration I", { name = "Ice Bite I", level = 1 } } })
check(atomic.ok and type(atomic.result.group) == "number", "createSocketGroup with gems returns a group")
check(#atomic.result.gems == 3 and atomic.result.gems[1].name == "Fireball",
	"createSocketGroup populated the whole link in one call (#4)")
check(atomic.result.gems[2].support == true, "the link's 2nd gem is a support")
check(atomic.result.stats ~= nil and atomic.result.stats.Life ~= nil, "createSocketGroup with gems recalcs + returns stats")
local atomicGroup = atomic.result.group
-- a bad gem name in the list errors clearly (with the entry index)
local badAtomic = call("createSocketGroup", { gems = { "Fireball", "Zzz Not A Gem" } })
check(not badAtomic.ok and badAtomic.error:find("entry 2") ~= nil, "createSocketGroup reports a bad gem entry by index")

-- #3: compatibleWithGroup returns only supports PoB will let support the active skill.
local compat = call("searchGems", { compatibleWithGroup = atomicGroup, limit = 300 })
check(compat.ok and compat.result.total >= 1, "searchGems compatibleWithGroup returns matches")
local allSupportsCompat = true
for _, g in ipairs(compat.result.gems) do if g.support ~= true then allSupportsCompat = false end end
check(allSupportsCompat, "compatibleWithGroup returns only support gems (#3)")
-- it should be a STRICT subset of all supports (discriminates, not pass-through)
local allSup = call("searchGems", { support = true, limit = 1000 })
check(compat.result.total < allSup.result.total,
	"compatibleWithGroup is a strict subset of all supports (filters incompatible ones)")
-- a known-compatible support (Fire Penetration I on Fireball) is present
local hasFirePen = false
for _, g in ipairs(call("searchGems", { compatibleWithGroup = atomicGroup, query = "Fire Penetration", limit = 50 }).result.gems) do
	if g.name == "Fire Penetration I" then hasFirePen = true end
end
check(hasFirePen, "compatibleWithGroup includes a genuinely compatible support")
-- error path: a group with no active skill
local emptyGrp = call("createSocketGroup", {})
local compatBad = call("searchGems", { compatibleWithGroup = emptyGrp.result.group })
check(not compatBad.ok and compatBad.error:find("no active skill") ~= nil,
	"compatibleWithGroup errors on a group with no active skill")

-- 17. #7 (cheap slice): set_gem / remove_gem accept a gem NAME selector (no index tracking).
local nameGrp = call("createSocketGroup", { gems = { "Fireball", "Fire Penetration I" } }).result.group
-- set by name
local setByName = call("setGem", { group = nameGrp, name = "Fireball", level = 12 })
check(setByName.ok and setByName.result.name == "Fireball" and setByName.result.level == 12,
	"setGem targets a gem by name (#7)")
-- name resolves case-insensitively + via the exact tiered name
local setSup = call("setGem", { group = nameGrp, name = "fire penetration i", quality = 5 })
check(setSup.ok and setSup.result.name == "Fire Penetration I" and setSup.result.quality == 5,
	"setGem name match is case-insensitive and tier-exact")
-- not-found + bad selector errors are clear
local nf = call("setGem", { group = nameGrp, name = "Nonexistent Gem" })
check(not nf.ok and nf.error:find("no gem named") ~= nil, "setGem on an unknown gem name errors clearly")
local noSel = call("setGem", { group = nameGrp })
check(not noSel.ok and noSel.error:find("'index' or a gem 'name'") ~= nil,
	"setGem with neither index nor name errors clearly")
-- remove by name
local lenBefore = #build.skillsTab.socketGroupList[nameGrp].gemList
local rmByName = call("removeGem", { group = nameGrp, name = "Fire Penetration I" })
check(rmByName.ok and rmByName.result.removed == "Fire Penetration I"
	and rmByName.result.remaining == lenBefore - 1, "removeGem targets a gem by name (#7)")
-- index still works alongside name
local rmByIdx = call("removeGem", { group = nameGrp, index = 1 })
check(rmByIdx.ok and rmByIdx.result.remaining == lenBefore - 2, "removeGem by index still works")

-- 30. Phase A: account status is a synchronous, network-free token read.
local as = call("accountStatus")
check(as.ok and type(as.result.signedIn) == "boolean" and type(as.result.needsAuth) == "boolean",
	"accountStatus returns signedIn/needsAuth booleans")
check(as.result.signedIn == false and as.result.needsAuth == true,
	"accountStatus reports signed-out in the headless harness (no persisted token)")

-- 31. Async-job primitive: jobPoll contract (pending stays, done/error drop one-shot).
-- The networked starters (listCharacters/importCharacter) can't complete headless
-- (no LuaSocket), so drive Bridge.jobs directly to assert the poll/drop semantics.
local badPoll = call("jobPoll", { jobId = 999999 })
check(not badPoll.ok and badPoll.error:find("unknown jobId") ~= nil, "jobPoll rejects an unknown jobId")

Bridge.jobs[424242] = { status = "pending" }
local p1 = call("jobPoll", { jobId = 424242 })
check(p1.ok and p1.result.status == "pending", "jobPoll returns pending while the job is unresolved")
check(Bridge.jobs[424242] ~= nil, "a pending job is not dropped on poll")

Bridge.jobs[424242].status = "done"
Bridge.jobs[424242].result = { hello = "world" }
local p2 = call("jobPoll", { jobId = 424242 })
check(p2.ok and p2.result.status == "done" and p2.result.result.hello == "world",
	"jobPoll returns the result once the job is done")
check(Bridge.jobs[424242] == nil, "a finished job is dropped after it is read (one-shot)")
local p3 = call("jobPoll", { jobId = 424242 })
check(not p3.ok and p3.error:find("unknown jobId") ~= nil, "polling a dropped job errors")

-- 32. Phase B: trade stat discovery (uses bundled TradeSiteStats; deterministic).
local ts = call("searchTradeStats", { query = "maximum life", limit = 5 })
check(ts.ok and ts.result.total >= 1 and #ts.result.stats >= 1, "searchTradeStats finds 'maximum life' entries")
local lifeStat = ts.result.stats[1]
check(lifeStat and type(lifeStat.id) == "string" and lifeStat.id ~= "", "searchTradeStats returns a usable stat id")
local tsTyped = call("searchTradeStats", { query = "resistance", type = "explicit", limit = 8 })
local allExplicit = tsTyped.ok and #tsTyped.result.stats >= 1
for _, s in ipairs(tsTyped.result.stats or {}) do if s.type ~= "explicit" then allExplicit = false end end
check(allExplicit, "searchTradeStats type filter returns only that category")

-- 33. searchTrade builds a valid trade2 query (inspect the enqueued request; no network).
local st = call("searchTrade", { league = "Standard", category = "accessory.ring", rarity = "rare",
	budget = 5, currency = "divine", minItemLevel = 80, sockets = 1,
	stats = { { id = lifeStat.id, min = 80 } } })
check(st.ok and st.result.jobId ~= nil and st.result.status == "pending", "searchTrade starts a pending job")
local searchQueue = Bridge.tradeRequests and Bridge.tradeRequests.requestQueue["search"]
check(searchQueue and #searchQueue >= 1, "searchTrade enqueued a search request")
local builtQuery = searchQueue and searchQueue[#searchQueue] and json.decode(searchQueue[#searchQueue].body)
check(builtQuery and builtQuery.query and builtQuery.query.status.option == "online", "built query has online status")
check(builtQuery.query.filters.type_filters.filters.category.option == "accessory.ring", "built query carries the category")
check(builtQuery.query.filters.type_filters.filters.rarity.option == "rare", "built query carries the rarity")
check(builtQuery.query.filters.trade_filters.filters.price.max == 5, "built query carries the budget")
check(builtQuery.query.filters.misc_filters.filters.ilvl.min == 80, "built query carries item level")
check(builtQuery.query.filters.equipment_filters.filters.rune_sockets.min == 1, "built query carries socket min")
check(builtQuery.query.stats[1].type == "and" and builtQuery.query.stats[1].filters[1].id == lifeStat.id
	and builtQuery.query.stats[1].filters[1].value.min == 80, "built query carries the stat filter")

-- 34. currencyRates serves a populated in-memory cache synchronously (no job).
local tradeQuery = build.itemsTab and build.itemsTab.tradeQuery
check(tradeQuery ~= nil, "itemsTab.tradeQuery exists headlessly")
if tradeQuery then
	tradeQuery.pbCurrencyConversion["TestLeague"] = { divine = 1, exalted = 0.05 }
	local cr = call("currencyRates", { league = "TestLeague" })
	check(cr.ok and cr.result.cached == true and cr.result.rates.exalted == 0.05, "currencyRates returns the cached rate map")
end

-- 35. priceItem errors clearly on an empty slot; listLeagues starts a job.
local pe = call("priceItem", { league = "Standard", slot = "Ring 1" })
check(not pe.ok and pe.error:find("empty") ~= nil, "priceItem errors on an empty slot")
local ll = call("listLeagues")
check(ll.ok and ll.result.jobId ~= nil, "listLeagues starts a job")

-- 37. priceItem prices a PASTED item (rawText) without touching the build.
local sampleUnique
for _, it in pairs(main.uniqueDB and main.uniqueDB.list or {}) do sampleUnique = it break end
check(sampleUnique ~= nil and sampleUnique.raw ~= nil, "a sample unique with raw text is available")
if sampleUnique and sampleUnique.raw then
	local searchLenBefore = #Bridge.tradeRequests.requestQueue["search"]
	local pi = call("priceItem", { league = "Standard", rawText = sampleUnique.raw, convert = false })
	check(pi.ok and pi.result.jobId ~= nil, "priceItem accepts pasted rawText and starts a job")
	check(#Bridge.tradeRequests.requestQueue["search"] == searchLenBefore + 1,
		"priceItem(rawText) enqueued a comparable search without an equipped slot")
end

print("\n" .. (failed and "RESULT: FAILURES" or "RESULT: ALL PASS"))
os.exit(failed and 1 or 0)
