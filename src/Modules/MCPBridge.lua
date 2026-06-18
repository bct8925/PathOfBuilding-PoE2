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
		stats = readStats(build, params and params.stats),
	}
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
	build.buildFlag = true
	Bridge.lastUndoScope = "config"
	return {
		var = params.var,
		value = input[params.var],
		stats = recalcAndRead(build, params.stats),
	}
end

-- FR-8: allocate or deallocate a passive node on the live tree, recalc.
-- params: { nodeId = <number>, alloc = <bool> }  (alloc defaults to true)
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
	if alloc then
		spec:AllocNode(node)
	else
		spec:DeallocNode(node)
	end
	spec:AddUndoState()
	build.buildFlag = true
	Bridge.lastUndoScope = "tree"
	return {
		nodeId = nodeId,
		nodeName = node.dn or node.name,
		alloc = node.alloc or false,
		allocatedNodeCount = spec:CountAllocNodes(),
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
	ConPrintf("[MCP bridge] listening on 127.0.0.1:%d", self.port)
end

function Bridge:stop()
	for _, c in ipairs(self.clients) do
		pcall(function() c.sock:close() end)
	end
	self.clients = {}
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
