-- optimize.lua — scoring + reporting for the optimize/search flow.
--
-- Direct Lua port of engine/optimize.ts. The AI proposes candidate change-sets; the
-- headless backend evaluates each off a snapshot and returns per-trial stats. Here we
-- score those trials against the AI-chosen objective, pick the winner, and compute the
-- stat deltas. Objective: exactly one of maximize / minimize / weights, plus optional
-- per-stat constraints {min?,max?}.

local M = {}

local INF = math.huge

local function num(v)
	if type(v) == "number" then
		return v
	end
	return nil
end

local function scoreOne(stats, obj)
	if obj.weights then
		local s = 0
		for k, w in pairs(obj.weights) do
			s = s + (num(stats[k]) or 0) * w
		end
		return s
	end
	if obj.minimize then
		return -(num(stats[obj.minimize]) or INF)
	end
	local key = obj.maximize
	if not key then
		return 0
	end
	return num(stats[key]) or -INF
end

local function violationsOf(stats, obj)
	local out = {}
	for k, c in pairs(obj.constraints or {}) do
		local v = num(stats[k])
		if v == nil then
			out[#out + 1] = k -- constrained stat missing → treat as violated
		elseif c.min ~= nil and v < c.min then
			out[#out + 1] = k
		elseif c.max ~= nil and v > c.max then
			out[#out + 1] = k
		end
	end
	return out
end

-- Score every trial; errored trials get no score and are never feasible.
function M.scoreTrials(trials, obj)
	local scored = {}
	for i, t in ipairs(trials) do
		if not t.ok or not t.stats then
			scored[i] = { label = t.label, ok = t.ok, stats = t.stats, error = t.error, violations = {}, feasible = false }
		else
			local violations = violationsOf(t.stats, obj)
			scored[i] = {
				label = t.label,
				ok = t.ok,
				stats = t.stats,
				error = t.error,
				score = scoreOne(t.stats, obj),
				violations = violations,
				feasible = #violations == 0,
			}
		end
	end
	return scored
end

local function rankTop(xs)
	local best
	for _, t in ipairs(xs) do
		if best == nil or (t.score or -INF) > (best.score or -INF) then
			best = t
		end
	end
	return best
end

-- Pick the winner: highest-scoring FEASIBLE trial, else highest-scoring overall with a
-- flag so the caller can report "no candidate met the constraints".
function M.pickWinner(scored)
	local feasible = {}
	for _, t in ipairs(scored) do
		if t.feasible then
			feasible[#feasible + 1] = t
		end
	end
	if #feasible > 0 then
		return rankTop(feasible), true
	end
	local scorable = {}
	for _, t in ipairs(scored) do
		if t.score ~= nil then
			scorable[#scorable + 1] = t
		end
	end
	if #scorable > 0 then
		return rankTop(scorable), false
	end
	return nil, false
end

-- Stat deltas winner-vs-baseline for numeric keys present (and differing) in both.
function M.statDeltas(baseline, winner)
	local out = {}
	if type(baseline) ~= "table" or type(winner) ~= "table" then
		return out
	end
	for k in pairs(winner) do
		local a, b = num(baseline[k]), num(winner[k])
		if a ~= nil and b ~= nil and a ~= b then
			out[k] = { from = a, to = b, delta = b - a }
		end
	end
	return out
end

return M
