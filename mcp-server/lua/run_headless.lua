-- run_headless.lua — headless calc runner driven by the Node MCP server.
--
-- Invoke with cwd = <repo>/src, LUA_PATH pointing at runtime/lua, e.g.:
--   cd src && LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;" \
--     CI=true luajit ../mcp/lua/run_headless.lua
--
-- Protocol: reads one JSON request object from stdin, writes one result line to
-- stdout prefixed with the RESULT_PREFIX sentinel (boot logs share stdout, so the
-- Node side keys on this prefix). Request shape:
--   { "action": "compute", "buildXml": "<xml>"?, "name": "..."?, "stats": [..]? }

local RESULT_PREFIX = "@@POB_RESULT@@"
local json = require("dkjson")

-- Read the request before booting (stdin is fully buffered by the caller).
local rawRequest = io.read("*a") or ""

-- Boot the full engine. Relative paths require cwd = src/.
dofile("HeadlessWrapper.lua")

-- Stats returned by default when the request doesn't name specific keys.
local DEFAULT_STATS = {
	"Life", "EnergyShield", "Mana", "Ward",
	"TotalDPS", "CombinedDPS", "FullDPS", "AverageDamage", "Speed",
	"CritChance", "CritMultiplier",
	"FireResist", "ColdResist", "LightningResist", "ChaosResist",
}

local function collectStats(keys)
	local out, output = {}, build.calcsTab.mainOutput or {}
	for _, k in ipairs(keys) do
		local v = output[k]
		if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
			out[k] = v
		end
	end
	return out
end

-- Load a fresh build from the snapshot XML (or the default empty build), then run
-- one frame so the engine settles. Shared by compute and search.
local function loadSnapshot(buildXml, name)
	if buildXml and #buildXml > 0 then
		loadBuildFromXML(buildXml, name or "MCP Build")
	else
		newBuild()
	end
	runCallback("OnFrame")
end

-- FR-13: evaluate many candidate change-sets off a build snapshot. Each candidate
-- is { label?, ops = [{ method, params }] } where the ops name MCPBridge mutator
-- handlers. We reuse the in-app bridge's dispatch (Bridge:handleLine) so a trial
-- runs the EXACT code path that applies the winner live (OQ-4 determinism). Each
-- candidate is evaluated against a FRESH reload of the snapshot for isolation.
-- The engine boots once (expensive); per-candidate cost is just a build reload.
local function runSearch(req)
	local Bridge = LoadModule("Modules/MCPBridge")
	local statKeys = req.stats or DEFAULT_STATS
	local snapshot = req.buildXml

	-- Baseline: the snapshot itself (empty change-set), for stat deltas.
	loadSnapshot(snapshot)
	Bridge.build = build
	local baseResp = Bridge:handleLine(json.encode({
		id = 0, method = "applyChangeSet", params = { ops = {}, stats = statKeys },
	}))
	local baseline = baseResp.ok and baseResp.result.stats or collectStats(statKeys)

	local results = {}
	for i, cand in ipairs(req.candidates or {}) do
		loadSnapshot(snapshot)
		Bridge.build = build
		local resp = Bridge:handleLine(json.encode({
			id = i,
			method = "applyChangeSet",
			params = { ops = cand.ops or {}, stats = statKeys },
		}))
		results[i] = {
			label = cand.label or tostring(i),
			ok = resp.ok and true or false,
			stats = resp.ok and resp.result.stats or nil,
			error = (not resp.ok) and resp.error or nil,
		}
	end
	return { ok = true, baseline = baseline, results = results }
end

local function handle(req)
	local action = req.action or "compute"
	if action == "compute" then
		loadSnapshot(req.buildXml, req.name or "MCP Build")
		return {
			ok = true,
			className = build.spec and build.spec.curClassName,
			ascendancy = build.spec and build.spec.curAscendClassName,
			level = build.characterLevel,
			mainSkill = build.calcsTab.mainEnv and build.calcsTab.mainEnv.player
				and build.calcsTab.mainEnv.player.mainSkill
				and build.calcsTab.mainEnv.player.mainSkill.activeEffect
				and build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name or nil,
			stats = collectStats(req.stats or DEFAULT_STATS),
		}
	elseif action == "search" then
		return runSearch(req)
	end
	error("unknown action: " .. tostring(action))
end

local req = {}
if #rawRequest > 0 then
	local decoded, _, err = json.decode(rawRequest)
	if err then
		print(RESULT_PREFIX .. json.encode({ ok = false, error = "bad request JSON: " .. err }))
		return
	end
	req = decoded
end

local ok, result = pcall(handle, req)
if ok then
	print(RESULT_PREFIX .. json.encode(result))
else
	print(RESULT_PREFIX .. json.encode({ ok = false, error = tostring(result) }))
end
