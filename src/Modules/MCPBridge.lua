-- Path of Building
--
-- Module: MCP Bridge
-- In-app socket bridge for the LIVE PoB2 GUI.
--
-- This module is loaded into a *running* PoB2 instance (lazily, only when the
-- "Enable MCP bridge" Option is on) and opens a local TCP server. The Node MCP
-- server (mcp/src/bridge/socket.ts) connects to it so that MCP tool calls can
-- read and MUTATE the GUI's in-memory build state live, then read refreshed
-- stats back.
--
-- Protocol (newline-delimited JSON, one object per line):
--   request:  {"id":N,"method":"<name>","params":{...}}
--   response: {"id":N,"ok":true,"result":{...}}  |  {"id":N,"ok":false,"error":"..."}
--
-- The server is non-blocking: `Bridge:pump()` is called once per frame from
-- main:OnFrame (see main:PumpMCPBridge). It must never block or throw out to the
-- frame loop — handler errors are caught and returned as error responses.

-- `socket` is required lazily in Bridge:start so this module can be loaded
-- (and its handlers exercised) under environments without LuaSocket, e.g. the
-- Linux headless test harness where only the Windows socket.dll ships.
local json = require("dkjson")

local t_insert = table.insert
local t_remove = table.remove
local m_min = math.min
local m_max = math.max

local Bridge = { clients = {}, server = nil, port = 8843, lastUndoScope = nil }

-- A curated default set of stats returned by getBuild / after each mutation.
local DEFAULT_STATS = {
	"Life", "LifeUnreserved", "EnergyShield", "Mana", "Ward",
	"TotalDPS", "FullDPS", "CombinedDPS", "TotalEHP",
	"CritChance", "CritMultiplier", "Speed",
	"FireResist", "ColdResist", "LightningResist", "ChaosResist",
}

-- Read selected stats out of the live calc output.
local function readStats(build, keys)
	local out = build.calcsTab.mainOutput or {}
	local stats = {}
	for _, k in ipairs(keys or DEFAULT_STATS) do
		stats[k] = out[k]
	end
	return stats
end

-- The meaningful allocated picks of a tree: its Notables and Keystones (the
-- generic +attribute / small passives are noise for a caller deciding what to do).
-- Lets getBuild hand back what the build has taken WITHOUT the assistant guessing.
local function allocatedNotables(spec)
	local out = {}
	if not spec then return out end
	for _, node in pairs(spec.allocNodes or {}) do
		if node.type == "Notable" or node.type == "Keystone" then
			t_insert(out, { id = node.id, name = node.dn or node.name, type = node.type })
		end
	end
	return out
end

-- Snapshot every scalar entry of an output table. Non-scalars (nested tables,
-- functions) are skipped: they're rebuilt with a fresh identity each pass and
-- aren't part of the user-facing stat values, so including them would make the
-- output look perpetually "unsettled".
local function scalarSnapshot(out)
	local snap = {}
	for k, v in pairs(out) do
		local t = type(v)
		if t == "number" or t == "string" or t == "boolean" then
			snap[k] = v
		end
	end
	return snap
end

-- True if two scalar snapshots are identical (same keys, same values).
local function snapshotsMatch(a, b)
	if not a or not b then return false end
	for k, v in pairs(a) do if b[k] ~= v then return false end end
	for k, v in pairs(b) do if a[k] ~= v then return false end end
	return true
end

-- Force an immediate recalc and return the refreshed stats. Mutators set
-- build.buildFlag = true; rather than wait for the next frame, we run the same
-- recalc the frame loop would (Build.lua OnFrame) right here so the response
-- carries the already-updated numbers.
--
-- A *structural* change (notably a passive-tree undo, which re-imports the node
-- list) can need more than one BuildOutput pass before the output reflects the
-- new state — the GUI gets this for free across successive rendered frames, but
-- a single inline pass would read a stale value. So we settle: re-run the recalc
-- until the *entire* scalar output stops changing between passes (bounded),
-- mirroring multiple frames. Comparing the whole output (not just a couple of
-- headline stats) means a stat that lags behind Life/DPS can't slip through.
local SETTLE_PASSES = 6

local function recalcAndRead(build, keys)
	if not build.buildFlag then
		return readStats(build, keys)
	end
	build.buildFlag = false
	local prev
	local settled = false
	for pass = 1, SETTLE_PASSES do
		-- Mirror Build:OnFrame's buildFlag block, RefreshStatList included: that
		-- post-pass refresh is what lets the *next* BuildOutput observe the new
		-- state, so a structural change settles in two passes instead of never.
		wipeGlobalCache()
		build.outputRevision = (build.outputRevision or 0) + 1
		build.calcsTab:BuildOutput()
		build:RefreshStatList()
		local snap = scalarSnapshot(build.calcsTab.mainOutput or {})
		if snapshotsMatch(prev, snap) then
			settled = true
			break
		end
		prev = snap
	end
	if not settled then
		-- Output values are correct (each post-refresh pass is internally
		-- consistent); we just couldn't confirm stability. Surface it rather than
		-- silently returning a possibly-mid-settle read.
		ConPrintf("[MCP bridge] recalc did not stabilise within %d passes", SETTLE_PASSES)
	end
	return readStats(build, keys)
end

-- Strip PoB's inline colour codes from a display string: `^x` + 6 hex digits
-- (e.g. ^xFF0000) or `^` + a single palette digit (e.g. ^8). The breakdown lines
-- PoB builds for the GUI are peppered with these; the MCP wants plain text.
local function stripColor(s)
	if type(s) ~= "string" then return s end
	return (s:gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""))
end

-- Serialize one breakdown row (a table of cell values keyed by colList keys) to
-- a JSON-friendly object: keep scalar cells (colour-stripped), drop nested tables
-- (e.g. a row's `.item` back-reference) and functions.
local function serializeRow(row)
	local out = {}
	for k, v in pairs(row) do
		local t = type(v)
		if t == "string" then
			out[k] = stripColor(v)
		elseif t == "number" or t == "boolean" then
			out[k] = v
		end
	end
	return out
end

-- PoB's per-tab undo relies on the stack already holding the current state, so
-- that after an edit (mutate -> AddUndoState) the *previous* state sits at
-- undo[2] for Undo() to restore. Tabs seed this via ResetUndo() when a build is
-- loaded, but a freshly-created build's config stack can be empty. Seed it with
-- the pre-change state before the first MCP mutation so undo is always reliable.
local function ensureUndoSeed(undoHandler)
	if not undoHandler.undo[1] then
		undoHandler:ResetUndo()
	end
end

-- FR-16 helpers. PoB sanitises build names by replacing path-hostile characters
-- with '-' (mirrors Build:OpenSaveAsPopup's EditControl filter).
local function sanitizeBuildName(name)
	return (name:gsub("[\\/:%*%?\"<>|%c]", "-"))
end

-- Serialise the build and write it to its dbFileName. We do the I/O here rather
-- than calling build:SaveDBFile() because that pops BLOCKING dialogs (a Save-As
-- prompt when the build was never saved, an error popup on write failure) which
-- would freeze the GUI frame loop the bridge is pumped from.
local function writeBuild(build)
	local xmlText = build:SaveDB(build.dbFileName)
	if not xmlText then
		error("failed to serialise the build to XML")
	end
	local file, ferr = io.open(build.dbFileName, "w+")
	if not file then
		error("couldn't write build file '" .. build.dbFileName .. "': " .. tostring(ferr))
	end
	file:write(xmlText)
	file:close()
	build:ResetModFlags()
end

-- FR-10 helpers. Resolve a socket group by 1-based index, defaulting to the
-- build's main socket group.
local function getSocketGroup(build, groupIndex)
	local skillsTab = build.skillsTab
	local idx = tonumber(groupIndex) or build.mainSocketGroup
	local group = skillsTab.socketGroupList[idx]
	if not group then
		error("no socket group at index " .. tostring(idx) ..
			" (build has " .. #skillsTab.socketGroupList .. " group(s))")
	end
	return group, idx
end

-- After mutating a socket group's gemList, refresh the skills editor IF that group
-- is the one currently open in it. The editor's gem rows (name/level/quality
-- EditControls) are loaded by SetDisplayGroup and only the trailing empty slot is
-- re-synced each frame — so a bridge edit to the displayed group would otherwise
-- leave stale text on screen even though the calc is correct (the level-field bug
-- class). No-op when a different group (or none) is displayed, or headless.
local function refreshGemEditor(skillsTab, group)
	if skillsTab.displayGroup == group and skillsTab.SetDisplayGroup then
		skillsTab:SetDisplayGroup(group)
	end
end

-- A fresh gem-instance table mirroring the GUI's CreateGemSlot defaults. With no
-- explicit level we flag it `new` so ProcessSocketGroup picks the gem's natural
-- max level (as the GUI does); an explicit level is clamped by validateGemLevel.
local function newGemInstance(params)
	local gem = {
		nameSpec = "",
		quality = tonumber(params.quality) or 0,
		enabled = params.enabled ~= false,
		enableGlobal1 = true,
		enableGlobal2 = true,
		count = 1,
		corrupted = false,
		corruptLevel = 0,
	}
	if params.level then
		gem.level = tonumber(params.level)
	else
		gem.level = 1
		gem.new = true
	end
	return gem
end

-- FR-9 (discovery) helpers. Mirror setItemRoll's ranged-line test so getItems
-- reports exactly which explicit mods are roll-addressable, and parse the
-- "(min-max)" bounds so the caller can reason about a roll without guessing.
local function rangedBounds(line)
	local lo, hi = line:match("%((%-?%d+%.?%d*)%-(%-?%d+%.?%d*)%)")
	if not lo then return nil end
	return tonumber(lo), tonumber(hi)
end

-- Serialise one item for getItems: identity + explicit mod lines with their roll
-- metadata (modIndex is the setItemRoll target), implicits/enchants as plain
-- context, and the canonical raw text for full inspection / round-trip.
local function describeItem(item, slotName, includeRaw)
	local explicitMods = {}
	for i, modLine in ipairs(item.explicitModLines or {}) do
		local lo, hi = rangedBounds(modLine.line)
		local entry = { modIndex = i, line = stripColor(modLine.line), ranged = lo ~= nil }
		if lo then
			entry.range = modLine.range -- current 0..1 (nil = unset)
			entry.min, entry.max = lo, hi
			if modLine.range then entry.value = lo + (hi - lo) * modLine.range end
		end
		t_insert(explicitMods, entry)
	end
	local function plainLines(modLines)
		local out = {}
		for _, ml in ipairs(modLines or {}) do t_insert(out, stripColor(ml.line)) end
		return out
	end
	local out = {
		slot = slotName,
		itemId = item.id,
		name = item.name,
		rarity = item.rarity,
		baseName = item.baseName,
		itemType = item.type,
		explicitMods = explicitMods,
		implicits = plainLines(item.implicitModLines),
		enchants = plainLines(item.enchantModLines),
	}
	if includeRaw and item.BuildRaw then out.raw = item:BuildRaw() end
	return out
end

-- method handlers: each receives (build, params) and returns a result table.
local methods = {}

-- FR-4/FR-5: identity + final computed stats of the live build.
function methods.getBuild(build, params)
	local spec = build.spec
	local mainSocketGroup = build.skillsTab and build.skillsTab.socketGroupList[build.mainSocketGroup]
	local mainSkillName
	if mainSocketGroup and mainSocketGroup.displaySkillList and mainSocketGroup.mainActiveSkill then
		local activeSkill = mainSocketGroup.displaySkillList[mainSocketGroup.mainActiveSkill]
		mainSkillName = activeSkill and activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
			and activeSkill.activeEffect.grantedEffect.name
	end
	return {
		className = spec and spec.curClassName,
		ascendancyName = spec and spec.curAscendClassName,
		level = build.characterLevel,
		mainSkill = mainSkillName,
		mainSocketGroup = build.mainSocketGroup,
		-- Tree readout so the assistant can SEE the current tree instead of guessing
		-- node ids (use searchPassives to find specific nodes + their distance).
		allocatedNodeCount = spec and spec:CountAllocNodes() or 0,
		allocatedNotables = allocatedNotables(spec),
		stats = readStats(build, params and params.stats),
	}
end

-- FR-6/FR-7: per-stat breakdown — how a value was derived, Calcs-tab style.
-- params: { stat = "<outputKey>" }  e.g. "Life", "FireResist", "CritChance",
-- "TotalDPS". Read-only: no mutation, no undo.
--
-- PoB records breakdowns only in its CALCS-mode calc pass, into
-- calcsTab.calcsEnv.player.breakdown[stat] (the MAIN pass that fills mainOutput
-- skips them for speed). A normal BuildOutput runs both passes, so we just make
-- sure the current state has been calculated, then read the recorded breakdown.
function methods.explainStat(build, params)
	if type(params.stat) ~= "string" then
		error("explainStat requires a string 'stat' (an output key, e.g. 'Life')")
	end
	local calcsTab = build.calcsTab
	-- Settle any pending change, else ensure at least one calc has run.
	if build.buildFlag then
		recalcAndRead(build)
	end
	if not calcsTab.calcsEnv then
		calcsTab:BuildOutput()
	end
	local player = calcsTab.calcsEnv.player
	local stat = params.stat
	local result = { stat = stat, value = (player.output or {})[stat] }

	local bd = player.breakdown and player.breakdown[stat]
	if not bd then
		-- Not every output key has a recorded breakdown; still hand back the value.
		result.note = "no per-stat breakdown recorded for '" .. stat ..
			"' (the value is returned regardless)"
		return result
	end

	-- A breakdown can carry an array of display lines AND/OR a structured table
	-- (label/footer + rowList|slots described by colList). Capture whatever's there.
	local lines = {}
	for _, line in ipairs(bd) do
		if type(line) == "string" then
			t_insert(lines, stripColor(line))
		end
	end
	if #lines > 0 then result.lines = lines end
	if bd.label then result.label = stripColor(bd.label) end
	if bd.footer then result.footer = stripColor(bd.footer) end

	local rows = {}
	for _, row in ipairs(bd.rowList or {}) do t_insert(rows, serializeRow(row)) end
	for _, row in ipairs(bd.slots or {}) do t_insert(rows, serializeRow(row)) end
	if #rows > 0 then result.rows = rows end
	if bd.colList then
		local cols = {}
		for _, col in ipairs(bd.colList) do
			t_insert(cols, { label = col.label, key = col.key })
		end
		result.columns = cols
	end
	return result
end

-- FR-11: toggle / set a Configuration-tab option, recalc, return new stats.
-- params: { var = "<configVarName>", value = <bool|number|string> }
function methods.setConfig(build, params)
	if type(params.var) ~= "string" then
		error("setConfig requires a string 'var'")
	end
	local configTab = build.configTab
	ensureUndoSeed(configTab)
	local input = configTab.configSets[configTab.activeConfigSetId].input
	if params.value == nil then
		input[params.var] = nil
	else
		input[params.var] = params.value
	end
	configTab:AddUndoState()
	configTab:BuildModList()
	-- Push the new input value into the visible config control (checkbox/edit/
	-- dropdown). The Config tab does NOT re-sync its controls from `input` every
	-- frame (only on load / config-set switch / search), so without this the calc
	-- updates but the on-screen control keeps showing the old value — the same
	-- stale-display class of bug as the level field. (Config undo/redo already
	-- refreshes via RestoreUndoState→UpdateControls.)
	if configTab.UpdateControls then configTab:UpdateControls() end
	build.buildFlag = true
	Bridge.lastUndoScope = "config"
	return {
		var = params.var,
		value = input[params.var],
		stats = recalcAndRead(build, params.stats),
	}
end

-- FR-8: allocate or deallocate a passive node on the live tree, recalc.
-- params: { nodeId = <number>, alloc = <bool>, maxPath = <number>? }
-- (alloc defaults to true). IMPORTANT: PoB's AllocNode auto-allocates the SHORTEST
-- PATH from the current tree to the target, so a distant node pulls in every
-- connecting node (and generic attribute nodes on that path default to Strength).
-- We therefore (a) reject an unconnectable node, (b) optionally cap the path length
-- via maxPath, and (c) report exactly which nodes the call added/removed so the
-- caller never mistakes a 10-node path for a single pick.
function methods.setPassive(build, params)
	local nodeId = tonumber(params.nodeId)
	if not nodeId then
		error("setPassive requires a numeric 'nodeId'")
	end
	local spec = build.spec
	ensureUndoSeed(spec)
	local node = spec.nodes[nodeId]
	if not node then
		error("no passive node with id " .. tostring(nodeId) .. " on the current tree")
	end
	local alloc = params.alloc ~= false -- default true

	-- Snapshot the allocated set so we can diff out the actual change set below.
	local before = {}
	for id in pairs(spec.allocNodes) do before[id] = true end

	if alloc then
		-- pathDist is "points from the current tree" (1000 == unreachable). Make sure
		-- it's current, then validate connectivity and the optional path-length cap
		-- BEFORE mutating, so a bad request changes nothing.
		spec:BuildAllDependsAndPaths()
		local dist = node.pathDist
		if not dist or dist >= 1000 then
			error("node " .. nodeId .. " (" .. (node.dn or node.name or "?") ..
				") is not connectable to the current tree")
		end
		local maxPath = tonumber(params.maxPath)
		if maxPath and dist > maxPath then
			error(("allocating node %d (%s) would path through %d point(s) (maxPath %d); "
				.. "raise 'maxPath' or pick a closer node (use searchPassives)")
				:format(nodeId, node.dn or node.name or "?", dist, maxPath))
		end
		spec:AllocNode(node)
	else
		spec:DeallocNode(node)
	end
	spec:AddUndoState()
	build.buildFlag = true
	Bridge.lastUndoScope = "tree"

	-- Diff before/after so the response lists every node this call actually changed
	-- (AllocNode pulls in the path; DeallocNode can cascade to dependents).
	local changedNodes = {}
	if alloc then
		for id, n in pairs(spec.allocNodes) do
			if not before[id] then
				t_insert(changedNodes, { id = id, name = n.dn or n.name, type = n.type })
			end
		end
	else
		for id in pairs(before) do
			if not spec.allocNodes[id] then
				local n = spec.nodes[id]
				t_insert(changedNodes, { id = id, name = n and (n.dn or n.name), type = n and n.type })
			end
		end
	end

	return {
		nodeId = nodeId,
		nodeName = node.dn or node.name,
		alloc = node.alloc or false,
		changedNodes = changedNodes,
		changedCount = #changedNodes,
		allocatedNodeCount = spec:CountAllocNodes(),
		stats = recalcAndRead(build, params.stats),
	}
end

-- FR-8 (discovery): search the passive tree so the assistant can find a node's id
-- and its distance from the current tree BEFORE allocating, instead of guessing.
-- Read-only. Matches `query` (plain, case-insensitive) against each node's display
-- name and stat lines, and reports node.pathDist (points-from-current-tree) so the
-- caller can pick a node that's actually on/near the frontier.
-- params: { query?, maxDist?, limit?, includeAllocated?, includeUnreachable? }
function methods.searchPassives(build, params)
	local spec = build.spec
	if not spec then error("no passive tree on the current build") end
	-- pathDist is maintained by AllocNode/Load; refresh it so a build that hasn't
	-- pathed this session still reports correct distances.
	spec:BuildAllDependsAndPaths()

	local query = type(params.query) == "string" and params.query:lower() or nil
	local maxDist = tonumber(params.maxDist)
	local limit = tonumber(params.limit) or 30
	local includeAllocated = params.includeAllocated == true
	local includeUnreachable = params.includeUnreachable == true

	local function matches(node)
		if not query then return true end
		if node.dn and node.dn:lower():find(query, 1, true) then return true end
		for _, line in ipairs(node.sd or {}) do
			if type(line) == "string" and line:lower():find(query, 1, true) then return true end
		end
		return false
	end

	local results = {}
	for _, node in pairs(spec.nodes) do
		-- Only real, allocatable passives: drop class/ascend starts, sockets, image-
		-- only proxies, and anything without a name/id.
		local t = node.type
		local allocatable = node.id and node.dn and t ~= "ClassStart"
			and t ~= "AscendClassStart" and t ~= "OnlyImage" and t ~= "Socket"
			and not node.isProxy
		if allocatable and (includeAllocated or not node.alloc) and matches(node) then
			local dist = node.pathDist
			local reachable = dist ~= nil and dist < 1000
			local distOk = (reachable and (not maxDist or dist <= maxDist))
				or (not reachable and includeUnreachable and not maxDist)
			if distOk then
				t_insert(results, {
					id = node.id,
					name = node.dn,
					type = node.type,
					alloc = node.alloc or false,
					pathDist = reachable and dist or nil,
					stats = node.sd,
				})
			end
		end
	end
	-- Nearest first; unreachable (no pathDist) sink to the end. Then cap.
	table.sort(results, function(a, b)
		return (a.pathDist or math.huge) < (b.pathDist or math.huge)
	end)
	local total = #results
	while #results > limit do t_remove(results) end
	return { query = params.query, total = total, returned = #results, nodes = results }
end

-- FR-10: choose the main socket group, and optionally the active skill within it.
-- params: { group = <1-based index>, activeSkill = <1-based index?> }
function methods.setMainSkill(build, params)
	local skillsTab = build.skillsTab
	local idx = tonumber(params.group)
	if not idx then
		error("setMainSkill requires a numeric 'group' (1-based socket group index)")
	end
	local group = skillsTab.socketGroupList[idx]
	if not group then
		error("no socket group at index " .. idx ..
			" (build has " .. #skillsTab.socketGroupList .. " group(s))")
	end
	ensureUndoSeed(skillsTab)
	build.mainSocketGroup = idx
	if params.activeSkill ~= nil then
		local skillIdx = tonumber(params.activeSkill)
		if not skillIdx then error("'activeSkill' must be numeric") end
		group.mainActiveSkill = skillIdx
	end
	skillsTab:AddUndoState()
	build.buildFlag = true
	Bridge.lastUndoScope = "skills"
	return {
		mainSocketGroup = build.mainSocketGroup,
		groupLabel = group.label,
		mainActiveSkill = group.mainActiveSkill,
		stats = recalcAndRead(build, params.stats),
	}
end

-- FR-10: add a gem (active skill or support) to a socket group, resolved by name
-- via PoB's fuzzy matcher. With no target group (and none on the build) a new
-- group is created and made the main group, so authoring from scratch works.
-- params: { group?, name, level?, quality?, enabled?, stats? }
function methods.addGem(build, params)
	local skillsTab = build.skillsTab
	if type(params.name) ~= "string" or not params.name:match("%S") then
		error("addGem requires a gem 'name'")
	end
	local errMsg, gemData = skillsTab:FindSkillGem(params.name)
	if not gemData then
		error(errMsg or ("unrecognised gem '" .. params.name .. "'"))
	end
	ensureUndoSeed(skillsTab)
	local group, groupIdx
	if params.group ~= nil then
		group, groupIdx = getSocketGroup(build, params.group)
	elseif skillsTab.socketGroupList[build.mainSocketGroup] then
		group, groupIdx = getSocketGroup(build)
	else
		group = { label = "", enabled = true, includeInFullDPS = true,
			groupCount = 1, mainActiveSkill = 1, gemList = {} }
		t_insert(skillsTab.socketGroupList, group)
		groupIdx = #skillsTab.socketGroupList
		build.mainSocketGroup = groupIdx
	end
	local gem = newGemInstance(params)
	gem.gemId = gemData.id
	t_insert(group.gemList, gem)
	skillsTab:ProcessSocketGroup(group)
	refreshGemEditor(skillsTab, group)
	skillsTab:AddUndoState()
	build.buildFlag = true
	Bridge.lastUndoScope = "skills"
	return {
		group = groupIdx,
		gemIndex = #group.gemList,
		name = gem.nameSpec,
		level = gem.level,
		quality = gem.quality,
		stats = recalcAndRead(build, params.stats),
	}
end

-- FR-10: remove a gem from a socket group by 1-based gemList index.
-- params: { group?, index, stats? }
function methods.removeGem(build, params)
	local skillsTab = build.skillsTab
	ensureUndoSeed(skillsTab)
	local group, groupIdx = getSocketGroup(build, params.group)
	local i = tonumber(params.index)
	if not i or not group.gemList[i] then
		error("removeGem requires a valid 1-based 'index' into the group's gemList")
	end
	local removed = group.gemList[i].nameSpec
	t_remove(group.gemList, i)
	skillsTab:ProcessSocketGroup(group)
	refreshGemEditor(skillsTab, group)
	skillsTab:AddUndoState()
	build.buildFlag = true
	Bridge.lastUndoScope = "skills"
	return {
		group = groupIdx,
		removed = removed,
		remaining = #group.gemList,
		stats = recalcAndRead(build, params.stats),
	}
end

-- FR-10: change a gem's level / quality / enabled state.
-- params: { group?, index, level?, quality?, enabled?, stats? }
function methods.setGem(build, params)
	local skillsTab = build.skillsTab
	ensureUndoSeed(skillsTab)
	local group, groupIdx = getSocketGroup(build, params.group)
	local i = tonumber(params.index)
	local gem = i and group.gemList[i]
	if not gem then
		error("setGem requires a valid 1-based 'index' into the group's gemList")
	end
	if params.level ~= nil then gem.level = tonumber(params.level) or gem.level end
	if params.quality ~= nil then gem.quality = tonumber(params.quality) or gem.quality end
	if params.enabled ~= nil then gem.enabled = params.enabled and true or false end
	skillsTab:ProcessSocketGroup(group) -- clamps level via validateGemLevel
	refreshGemEditor(skillsTab, group)
	skillsTab:AddUndoState()
	build.buildFlag = true
	Bridge.lastUndoScope = "skills"
	return {
		group = groupIdx,
		gemIndex = i,
		name = gem.nameSpec,
		level = gem.level,
		quality = gem.quality,
		enabled = gem.enabled,
		stats = recalcAndRead(build, params.stats),
	}
end

-- FR-9 (discovery): read the build's items so the assistant can find an item's id
-- and mod lines BEFORE editing, instead of only knowing items it added itself.
-- Read-only. Defaults to EQUIPPED items in display order; pass `slot` to read one,
-- or includeInventory=true to also list unequipped items in the build's item set.
-- params: { slot?, includeInventory?, includeRaw? }
function methods.getItems(build, params)
	local itemsTab = build.itemsTab
	local includeRaw = params.includeRaw ~= false -- default true
	local items = {}
	local equippedIds = {}

	local function addSlot(slot)
		local id = slot.selItemId
		if id and id ~= 0 then
			local item = itemsTab.items[id]
			if item then
				equippedIds[id] = true
				t_insert(items, describeItem(item, slot.slotName, includeRaw))
			end
		end
	end

	if params.slot then
		local slot = itemsTab.slots[params.slot]
		if not slot then
			error("no such equipment slot '" .. tostring(params.slot) .. "'")
		end
		addSlot(slot)
	else
		for _, slot in ipairs(itemsTab.orderedSlots) do addSlot(slot) end
	end

	local inventory
	if params.includeInventory then
		inventory = {}
		for id, item in pairs(itemsTab.items) do
			if not equippedIds[id] then
				t_insert(inventory, describeItem(item, nil, includeRaw))
			end
		end
	end

	return { items = items, equippedCount = #items, inventory = inventory }
end

-- FR-9: add an item to the live build from raw item text (the same format PoB's
-- "Create custom" / import uses). Optionally equip it: to an explicit `slot`, or
-- to the item's natural slot when `equip` is true. Recalc + return new stats.
-- params: { raw, equip?, slot?, stats? }
function methods.addItem(build, params)
	if type(params.raw) ~= "string" or not params.raw:match("%S") then
		error("addItem requires raw item text in 'raw'")
	end
	local itemsTab = build.itemsTab
	ensureUndoSeed(itemsTab)
	local item = new("Item", params.raw)
	if not item.base then
		error("could not parse item text (unknown or missing base type)")
	end
	itemsTab:AddItem(item, true) -- assigns item.id; we handle equipping explicitly
	local equippedSlot
	local slot = params.slot
	if slot or params.equip then
		slot = slot or item:GetPrimarySlot()
		if not itemsTab.slots[slot] then
			error("no such equipment slot '" .. tostring(slot) .. "'")
		end
		if not itemsTab:IsItemValidForSlot(item, slot) then
			error("item is not valid for slot '" .. slot .. "'")
		end
		itemsTab.slots[slot]:SetSelItemId(item.id)
		equippedSlot = slot
	end
	itemsTab:PopulateSlots()
	itemsTab:AddUndoState()
	build.buildFlag = true
	Bridge.lastUndoScope = "items"
	return {
		itemId = item.id,
		name = item.name,
		equippedSlot = equippedSlot or false,
		stats = recalcAndRead(build, params.stats),
	}
end

-- FR-9: equip an already-added item (by id) into a slot. `slot` defaults to the
-- item's natural primary slot. Recalc + return new stats.
-- params: { itemId, slot?, stats? }
function methods.equipItem(build, params)
	local itemsTab = build.itemsTab
	local itemId = tonumber(params.itemId)
	local item = itemId and itemsTab.items[itemId]
	if not item then
		error("no item with id " .. tostring(params.itemId) .. " in the build")
	end
	ensureUndoSeed(itemsTab)
	local slot = params.slot or item:GetPrimarySlot()
	if not itemsTab.slots[slot] then
		error("no such equipment slot '" .. tostring(slot) .. "'")
	end
	if not itemsTab:IsItemValidForSlot(item, slot) then
		error("item " .. itemId .. " is not valid for slot '" .. slot .. "'")
	end
	itemsTab.slots[slot]:SetSelItemId(item.id)
	itemsTab:PopulateSlots()
	itemsTab:AddUndoState()
	build.buildFlag = true
	Bridge.lastUndoScope = "items"
	return {
		itemId = item.id,
		slot = slot,
		stats = recalcAndRead(build, params.stats),
	}
end

-- FR-9: remove an item (by id) from the build. DeleteItem also unequips it from
-- any slot and clears jewel-socket references. Recalc + return new stats.
-- params: { itemId, stats? }
function methods.removeItem(build, params)
	local itemsTab = build.itemsTab
	local itemId = tonumber(params.itemId)
	local item = itemId and itemsTab.items[itemId]
	if not item then
		error("no item with id " .. tostring(params.itemId) .. " in the build")
	end
	ensureUndoSeed(itemsTab)
	itemsTab:DeleteItem(item) -- handles slot/jewel cleanup, PopulateSlots, AddUndoState
	build.buildFlag = true
	Bridge.lastUndoScope = "items"
	return {
		removed = itemId,
		stats = recalcAndRead(build, params.stats),
	}
end

-- FR-9: adjust a ranged roll on an item's explicit modifier. `range` is 0..1
-- (0 = minimum value, 1 = maximum) and only applies to mods PoB knows are ranged
-- (a "(min-max)" line). Rebuilds the item's mods, recalc + return new stats.
-- params: { itemId, modIndex, range, stats? }
function methods.setItemRoll(build, params)
	local itemsTab = build.itemsTab
	local itemId = tonumber(params.itemId)
	local item = itemId and itemsTab.items[itemId]
	if not item then
		error("no item with id " .. tostring(params.itemId) .. " in the build")
	end
	local idx = tonumber(params.modIndex)
	local modLine = idx and item.explicitModLines[idx]
	if not modLine then
		error("no explicit mod at index " .. tostring(params.modIndex) ..
			" (item has " .. #item.explicitModLines .. " explicit mod(s))")
	end
	local range = tonumber(params.range)
	if not range or range < 0 or range > 1 then
		error("setItemRoll requires a numeric 'range' between 0 and 1")
	end
	if not modLine.line:find("%((%-?%d+%.?%d*)%-(%-?%d+%.?%d*)%)") then
		error("mod #" .. idx .. " ('" .. modLine.line .. "') is not a ranged roll")
	end
	ensureUndoSeed(itemsTab)
	modLine.range = range
	item:BuildModList() -- re-evaluates ranged mods from modLine.range
	itemsTab:PopulateSlots()
	itemsTab:AddUndoState()
	build.buildFlag = true
	Bridge.lastUndoScope = "items"
	return {
		itemId = itemId,
		modIndex = idx,
		line = modLine.line,
		range = modLine.range,
		stats = recalcAndRead(build, params.stats),
	}
end

-- FR-17: drive PoB's native per-tab undo/redo stack. PoB has no single global
-- undo stack — each tab (tree/config/items/skills) is its own UndoHandler, and
-- the GUI's Ctrl+Z dispatches to the active tab. We mirror that: an explicit
-- `scope` selects the tab, defaulting to the scope of the last MCP mutation.
local undoTargets = {
	tree = function(build) return build.spec end,
	config = function(build) return build.configTab end,
	items = function(build) return build.itemsTab end,
	skills = function(build) return build.skillsTab end,
}

local function doUndoRedo(build, params, op)
	local scope = params.scope or Bridge.lastUndoScope
	if not scope then
		error(op .. " requires a 'scope' (tree|config|items|skills); no prior MCP mutation to infer it")
	end
	local getTarget = undoTargets[scope]
	if not getTarget then
		error("unknown undo scope: " .. tostring(scope))
	end
	local target = getTarget(build)
	target[op](target)
	build.buildFlag = true
	return { scope = scope, op = op, stats = recalcAndRead(build, params.stats) }
end

function methods.undo(build, params)
	return doUndoRedo(build, params, "Undo")
end

function methods.redo(build, params)
	return doUndoRedo(build, params, "Redo")
end

-- FR-8: change class / ascendancy (and optionally level) on the live build.
-- Mirrors the GUI's tree-class change: SelectClass resets the ascendancy and
-- SelectAscendClass rebuilds node paths. Class/ascendancy are resolved by name via
-- the tree's name maps (a numeric ascendancy id is also accepted). Recalc + new stats.
-- NOTE class/ascendancy changes ride the tree (spec) undo stack, but `level` is a
-- Build-level property that PoB keeps off the undo stacks — so a `tree` undo
-- reverts the class/ascendancy but NOT a level set here (matching the GUI, where
-- the level field isn't undoable). Re-set the level to change it back.
-- params: { className?, ascendancy?, level?, stats? }
function methods.setClass(build, params)
	local spec = build.spec
	local tree = spec.tree
	ensureUndoSeed(spec)
	if params.className ~= nil then
		if type(params.className) ~= "string" then error("'className' must be a string") end
		local classId = tree.classNameMap[params.className]
		if not classId then error("unknown class '" .. params.className .. "'") end
		spec:SelectClass(classId) -- resets ascendancy to 0 and rebuilds paths
	end
	if params.ascendancy ~= nil then
		local ascendId
		if type(params.ascendancy) == "number" then
			ascendId = params.ascendancy
		elseif type(params.ascendancy) == "string" and params.ascendancy:match("%S") then
			local entry = tree.ascendNameMap[params.ascendancy]
			if not entry or entry.classId ~= spec.curClassId then
				error("ascendancy '" .. params.ascendancy .. "' is not valid for class '" ..
					tostring(spec.curClassName) .. "'")
			end
			ascendId = entry.ascendClassId
		else
			ascendId = 0 -- empty string clears the ascendancy
		end
		spec:SelectAscendClass(ascendId)
	end
	if params.level ~= nil then
		local lvl = tonumber(params.level)
		if not lvl then error("'level' must be numeric") end
		build.characterLevel = m_min(m_max(lvl, 1), 100)
		build.characterLevelAutoMode = false
		-- Keep the GUI's level field + auto/manual button in sync. OnFrame re-syncs
		-- the class/ascend dropdowns from the spec each frame, but the level field is
		-- only ever pushed via SetText (on load / auto-level) — set it here too, or
		-- the field keeps showing the Init default while the calc uses the new value.
		-- Guarded so headless (controls present but graphics stubbed) stays happy.
		local controls = build.controls
		if controls then
			if controls.characterLevel then controls.characterLevel:SetText(tostring(build.characterLevel)) end
			if controls.levelScalingButton then controls.levelScalingButton.label = "Manual" end
		end
	end
	spec:BuildAllDependsAndPaths()
	spec:AddUndoState()
	build.buildFlag = true
	Bridge.lastUndoScope = "tree"
	return {
		className = spec.curClassName,
		ascendancyName = spec.curAscendClassName,
		level = build.characterLevel,
		stats = recalcAndRead(build, params.stats),
	}
end

-- FR-13/FR-14: apply an ordered change-set — a list of { method, params } that
-- name existing mutator handlers — to the build. Search evaluates a candidate by
-- replaying its change-set headlessly; applying the winner LIVE replays the very
-- same list through this method, so trial and live use one identical code path
-- (resolves OQ-4: the winning change set is a semantic op list, not an XML diff,
-- and re-applies deterministically onto the current live build). Stats read once
-- at the end. Each op still pushes its own undo state, matching PoB's granularity.
function methods.applyChangeSet(build, params)
	local ops = params.ops
	if type(ops) ~= "table" then
		error("applyChangeSet requires an 'ops' array")
	end
	for i, op in ipairs(ops) do
		if type(op) ~= "table" or type(op.method) ~= "string" then
			error("op " .. i .. ": each op needs a string 'method'")
		end
		if op.method == "applyChangeSet" then
			error("op " .. i .. ": applyChangeSet cannot be nested")
		end
		local handler = methods[op.method]
		if not handler then
			error("op " .. i .. ": unknown method '" .. op.method .. "'")
		end
		handler(build, op.params or {})
	end
	build.buildFlag = true
	return { applied = #ops, stats = recalcAndRead(build, params.stats) }
end

-- FR-3/FR-13: serialise the live build to XML in-memory (the same text SaveDB
-- writes to disk, but never touching the filesystem). Used to snapshot the live
-- build so headless search can evaluate trials off it without churning the GUI.
function methods.exportXml(build)
	local xml = build:SaveDB("snapshot")
	if not xml then
		error("failed to serialise the build to XML")
	end
	return {
		xml = xml,
		buildName = build.buildName,
		className = build.spec and build.spec.curClassName,
	}
end

-- FR-16: build lifecycle — new / save / save-as on the current build.
-- params: { action = "new" | "save" | "saveAs", name?, subPath?, className?,
--           ascendancy?, level?, stats? }
function methods.lifecycle(build, params)
	local action = params.action
	if action == "new" then
		-- FR-15/FR-16: replace the current build with a fresh one. main:SetMode is
		-- deferred (the swap runs at the START of the next OnFrame, after the bridge
		-- pump), so we'd return before the new build exists. Instead drive the same
		-- transition synchronously here: Shutdown then Init re-initialise the stable
		-- main.modes.BUILD table in place — so `build` (this handler's reference and
		-- the bridge's cached one) stays valid, no stale reference. We force
		-- abortSave=true first so Build:Shutdown's dev-mode autosave (which can pop a
		-- BLOCKING Save dialog) is skipped — same hazard writeBuild avoids.
		if params.name ~= nil and type(params.name) ~= "string" then
			error("'name' must be a string")
		end
		build.abortSave = true
		build:Shutdown()
		build:Init(false, params.name or "Unnamed build")
		local stats
		if params.className ~= nil or params.ascendancy ~= nil or params.level ~= nil then
			-- setClass recalcs and reads stats for us.
			stats = methods.setClass(build, params).stats
		else
			build.buildFlag = true
			stats = recalcAndRead(build, params.stats)
		end
		Bridge.lastUndoScope = "tree"
		return {
			action = "new",
			buildName = build.buildName,
			className = build.spec and build.spec.curClassName,
			ascendancyName = build.spec and build.spec.curAscendClassName,
			level = build.characterLevel,
			stats = stats,
		}
	elseif action == "save" then
		if not build.dbFileName then
			error("this build has never been saved; call lifecycle with action='saveAs' and a 'name'")
		end
		writeBuild(build)
	elseif action == "saveAs" then
		if type(params.name) ~= "string" or not params.name:match("%S") then
			error("saveAs requires a non-empty 'name'")
		end
		if not main.buildPath then
			error("PoB build path is unavailable; cannot resolve a save location")
		end
		local subPath = params.subPath or build.dbFileSubPath or ""
		local sanitized = sanitizeBuildName(params.name)
		build.dbFileName = main.buildPath .. subPath .. sanitized .. ".xml"
		build.buildName = sanitized
		build.dbFileSubPath = subPath
		writeBuild(build)
	else
		error("lifecycle requires action 'new', 'save' or 'saveAs' (got " .. tostring(action) .. ")")
	end
	return {
		action = action,
		saved = true,
		buildName = build.buildName,
		path = build.dbFileName,
	}
end

-- Lightweight liveness probe (used by the Node client to confirm reachability).
function methods.ping()
	return { pong = true }
end

function Bridge:start(build, port)
	local socket = require("socket")
	self.port = port or self.port
	local server, err = socket.bind("127.0.0.1", self.port)
	if not server then
		error("could not bind MCP bridge to 127.0.0.1:" .. tostring(self.port) .. ": " .. tostring(err))
	end
	self.server = server
	self.server:settimeout(0) -- non-blocking; pumped from OnFrame
	self.build = build
	self.clients = {}
	-- Keep PoB running OnFrame even when unfocused/minimized so the bridge is
	-- serviced off-screen. Provided by a patched SimpleGraphic (see
	-- scripts/simplegraphic-bridge-fix.md); guarded so it's a harmless no-op on
	-- an unpatched DLL (where the MCP server's auto-focus workaround handles it).
	if SetForceFrames then SetForceFrames(true) end
	ConPrintf("[MCP bridge] listening on 127.0.0.1:%d", self.port)
end

function Bridge:stop()
	for _, c in ipairs(self.clients) do
		pcall(function() c.sock:close() end)
	end
	self.clients = {}
	if SetForceFrames then SetForceFrames(false) end
	if self.server then
		pcall(function() self.server:close() end)
		self.server = nil
		ConPrintf("[MCP bridge] stopped")
	end
end

function Bridge:isRunning()
	return self.server ~= nil
end

-- Handle one request line: dispatch to a method handler, return a response table.
function Bridge:handleLine(line)
	local req = json.decode(line)
	if type(req) ~= "table" then
		return { ok = false, error = "malformed request (not a JSON object)" }
	end
	local handler = methods[req.method]
	if not handler then
		return { id = req.id, ok = false, error = "unknown method: " .. tostring(req.method) }
	end
	local ok, result = pcall(handler, self.build, req.params or {})
	if ok then
		return { id = req.id, ok = true, result = result }
	end
	return { id = req.id, ok = false, error = tostring(result) }
end

-- Call this once per frame from main:OnFrame. Never throws.
function Bridge:pump()
	if not self.server then return end

	-- Accept any newly-connecting clients (non-blocking).
	local client = self.server:accept()
	if client then
		client:settimeout(0)
		t_insert(self.clients, { sock = client, buf = "" })
	end

	-- Service each client: read complete lines, dispatch, reply.
	for i = #self.clients, 1, -1 do
		local c = self.clients[i]
		local data, err = c.sock:receive("*l")
		if data then
			local resp = self:handleLine(data)
			c.sock:send(json.encode(resp) .. "\n")
		elseif err == "closed" then
			pcall(function() c.sock:close() end)
			table.remove(self.clients, i)
		end
		-- err == "timeout" -> no full line yet this frame; try again next frame.
	end
end

return Bridge
