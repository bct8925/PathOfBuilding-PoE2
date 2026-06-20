-- tools/optimize.lua — gui_optimize: search AI-proposed candidate change-sets to an
-- objective and apply the winner live. Port of the index.ts gui_optimize handler.
--
-- Flow (FR-13/14): snapshot the live build (exportXml) → evaluate every candidate
-- headlessly off that snapshot (engine.search, no GUI churn) → score against the
-- AI-chosen objective → replay the winner's op-list live via applyChangeSet. Drift
-- (the live build changed since the snapshot) is detected by comparing SHA1 of the XML.
local S = require("tools.schema")

local changeOpSchema = {
	type = "object",
	properties = {
		method = S.str("MCPBridge mutator name (e.g. 'setPassive', 'addGem', 'setConfig', 'setItemRoll', 'setClass')."),
		params = S.object("Params for that mutator (same shape as the matching gui_* tool)."),
	},
	required = { "method" },
}

local objectiveSchema = {
	type = "object",
	description = "AI-chosen objective: exactly one of maximize/minimize/weights, plus optional constraints.",
	properties = {
		maximize = S.str("Maximize a single stat key (e.g. 'TotalDPS')."),
		minimize = S.str("Minimize a single stat key (e.g. 'ManaReserved')."),
		weights = S.object("Weighted blend: score = sum(weight*stat). Positive weight = higher-is-better."),
		constraints = S.object("Hard constraints per stat, e.g. { FireResist: { min: 75 } }. Trials violating any are infeasible."),
	},
}

return function(ctx)
	local bridge, engine, opt, json = ctx.bridge, ctx.engine, ctx.optimize, ctx.json
	local sha1 = require("sha1").sha1

	local function buildStatKeys(obj, reportStats)
		local seen, keys = {}, {}
		local function add(k)
			if k ~= nil and not seen[k] then
				seen[k] = true
				keys[#keys + 1] = k
			end
		end
		add(obj.maximize)
		add(obj.minimize)
		for k in pairs(obj.weights or {}) do add(k) end
		for k in pairs(obj.constraints or {}) do add(k) end
		for _, k in ipairs(reportStats or {}) do add(k) end
		return keys
	end

	local function run(args)
		local obj = args.objective or {}
		local statKeys = buildStatKeys(obj, args.reportStats)
		if #statKeys == 0 then
			error("objective is empty: set maximize, minimize, or weights", 0)
		end

		-- 1. Snapshot the live build (FR-3) and remember its identity for drift.
		local snap = bridge.raw("exportXml")
		local snapshotXml = snap.xml
		local snapshotHash = sha1(snapshotXml)

		-- Guarantee every candidate has a stable label so we can map winner -> ops.
		local labelled, opsByLabel = {}, {}
		for i, c in ipairs(args.candidates or {}) do
			local label = c.label or ("cand-" .. i)
			labelled[i] = { label = label, ops = c.ops or {} }
			opsByLabel[label] = c.ops or {}
		end

		-- 2. Evaluate all candidates headlessly off the snapshot.
		local search = engine.search({ buildXml = snapshotXml, candidates = labelled, stats = statKeys })
		if not search.ok or not search.results then
			error("headless search failed: " .. tostring(search.error or "no results"), 0)
		end

		-- 3. Score + pick the winner.
		local scored = opt.scoreTrials(search.results, obj)
		local winner, feasibleFound = opt.pickWinner(scored)
		if not winner then
			error("no candidate evaluated successfully", 0)
		end

		-- 4. Replay the winner live (unless suppressed or infeasible-and-not-forced).
		local shouldApply = args.apply ~= false and (winner.feasible or args.applyInfeasible == true)
		local applied, driftDetected = false, false
		if shouldApply then
			local live = bridge.raw("exportXml")
			driftDetected = sha1(live.xml) ~= snapshotHash
			bridge.raw("applyChangeSet", { ops = opsByLabel[winner.label] or {} })
			applied = true
		end

		local appliedNote
		if applied then
			appliedNote = "winner replayed onto the live build"
		elseif winner.feasible then
			appliedNote = "apply suppressed (apply=false)"
		else
			appliedNote = "winner is infeasible; not applied (set applyInfeasible=true to force)"
		end

		local trials = {}
		for i, t in ipairs(scored) do
			trials[i] = { label = t.label, ok = t.ok, score = t.score, feasible = t.feasible, violations = t.violations, error = t.error }
		end

		return {
			objective = obj,
			searchSpace = { candidateCount = #labelled, scoredStats = statKeys },
			winner = { label = winner.label, score = winner.score, feasible = winner.feasible, violations = winner.violations },
			applied = applied,
			appliedNote = appliedNote,
			feasibleFound = feasibleFound,
			driftDetected = driftDetected,
			driftNote = driftDetected
				and "the live build changed between snapshot and apply; the winner was replayed semantically over the current state"
				or nil,
			baseline = search.baseline,
			winnerStats = winner.stats,
			deltas = opt.statDeltas(search.baseline, winner.stats),
			trials = trials,
		}
	end

	ctx.register({
		name = "gui_optimize",
		description = "Search a set of AI-proposed candidate change-sets to an objective and apply the "
			.. "winner to the live build. Each candidate is an ordered list of mutator ops "
			.. "(the same methods the gui_* tools call). Trials run headlessly off a snapshot "
			.. "of the live build (the GUI doesn't churn through them); the best feasible "
			.. "candidate is then replayed live. Returns the objective, search space, winner, "
			.. "and stat deltas (FR-13/14).",
		schema = S.obj({
			objective = objectiveSchema,
			candidates = S.arr({
				type = "object",
				properties = {
					label = S.str("Human-readable label for this candidate."),
					ops = S.arr(changeOpSchema, "Ordered change-set to evaluate."),
				},
				required = { "ops" },
			}, "Candidate change-sets to evaluate (AI-proposed)."),
			apply = S.bool("Apply the winner to the live build (default true)."),
			applyInfeasible = S.bool("If no candidate meets the constraints, still apply the best-scoring one (default false)."),
			reportStats = S.arr(S.str(), "Extra stat keys to include in the report/deltas beyond the objective's keys."),
		}, { "objective", "candidates" }),
		handler = function(args)
			local ok, result = pcall(run, args)
			if ok then
				return { content = { { type = "text", text = json.encode(result, { indent = true }) } }, isError = false }
			end
			return {
				content = {
					{
						type = "text",
						text = "optimize failed: "
							.. tostring(result)
							.. '\nIs PoB2 running with the "Enable MCP bridge" Option on, and is the headless luajit available?',
					},
				},
				isError = true,
			}
		end,
	})
end
