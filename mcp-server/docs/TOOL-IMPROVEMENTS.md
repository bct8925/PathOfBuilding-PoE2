# Tool fixes & requests — from a live build-review session

Findings from a real `poe2-build` review session (Monk / Martial Artist, Earthshatter,
lvl 78). The build was healthy (~37.5k single-target DPS), but the tools led the assistant
to misdiagnose it as broken (8.2k DPS) and to make two confidently-wrong recommendations.
Each item below is something that, if fixed, would have prevented a specific wrong turn.

Priorities: **P0** = caused a material misdiagnosis; **P1** = forced slow manual
reverse-engineering; **P2** = polish.

---

## Resolution status (updated)

| Item | Status | Notes |
|---|---|---|
| **P0-1** skill part read + set | ✅ Done | `gui_explain_skill` returns `skillPartCount`/`skillParts`/`skillPartIndex`/`skillPartKind` + a `part` arg to read a specific part without mutating; `gui_set_main_skill { part }` switches it. PoB2 slams use **stat sets** (`grantedEffect.statSets`), not PoE1 `parts` — both mechanisms handled. |
| **P0-2** ascendancy cap vs unlocked | ✅ Done (relabel) | `gui_get_build` adds `ascendancyNote`; tool/skill docs say "ask about Trials first." The 3-state split isn't computable — PoB doesn't track Trial progress. |
| **P1-1** conditional summary hidden | ✅ Done | `gui_query_mods` adds `sumBaseActive`/`sumIncActive`/`moreMultiplierActive` (main-skill context) beside the unconditional totals, with a `summaryNote`. |
| **P1-2** opaque condition tags | ✅ Done | Each mod now carries `gates` resolving its condition/multiplier/skill name + current truth value. |
| **P1-3** hit-damage breakdown | ⏳ Spike | Needs investigation: does PoB retain a breakdown for `AverageHit`? Not promised yet. |
| **P1-4** empty `hit.byType` | ⏳ Re-test | Likely the same root cause as P0-1 (a part deals no direct hit). Re-test on the non-slam part now that part selection works. |
| **P2-1 / P2-2 / P2-3** | ⏳ Backlog | Polish. Note `gui_search_passives` already returns `alloc` per node. |
| **S-1 … S-5** skill guardrails | ✅ Done | Added to `poe2-build`: low-DPS checklist (`troubleshooting.md`), search-passives-is-suggestions + ascendancy-cap gotchas (`tool-cookbook.md`), verify-before-diagnose + separate-data-from-interpretation (`SKILL.md`, `build-order.md`). |

---

## P0-1 — Skill-part is invisible and uncontrollable (the big one)

**Symptom.** `gui_explain_skill` / `gui_get_build` reported `CombinedDPS: 8240` for
Earthshatter. The real number was `30445` — the tool was reporting the **slam** part of a
two-stage skill instead of the **shatter** (detonation) part. Nothing in any tool output
indicated *which* skill part the DPS represented, and there was no way to read or change it.
The user had to switch the part manually in the GUI before the number made sense.

**Impact.** The entire review opened with "your DPS is critically low," triggering a
re-roll-class discussion — for a build that was 3.7× stronger than reported.

**Requests.**
- Add a `skillPart` field (index + label, e.g. `2: "Shatter"`) to `gui_explain_skill` and to
  `gui_get_build`'s skill summary, plus the part **count**, so the consumer knows the number
  is part-specific and that other parts exist.
- Add a setter — e.g. `gui_set_skill_part(group, partIndex)` — or a `part` arg on
  `gui_explain_skill` to read a specific part without mutating the GUI selection.
- Multi-part skills (slams, `Duration`/`Trigger` skills) should be flagged so the assistant
  knows to enumerate parts before quoting DPS.

## P0-2 — `ascendancyTotal` reports the cap, not what's unlocked

**Symptom.** `gui_get_build` returned `ascendancyUsed: 4, ascendancyTotal: 8,
ascendancyRemaining: 4`. The user had only unlocked 4 points (trials not done); the other 4
were not actually available.

**Impact.** Led to a confident recommendation to "spend your 4 free ascendancy points" —
points that don't exist yet. User had to correct it.

**Request.** Distinguish three states instead of two: `ascendancyAllocated`,
`ascendancyUnlockedUnspent` (truly free now), and `ascendancyLockedBehindTrials`. If PoB
can't know trial progress, at least label `ascendancyTotal` as "max for this ascendancy
(may require trials)" so it isn't read as available.

---

## P1-1 — `gui_query_mods` summary hides conditional/flagged contributions

**Symptom.** `gui_query_mods{mod:"Damage"}` listed 16 real INC entries (Killer Instinct +40,
Crashing Wave +25, Stupefy +30, …) but the summary line read `sumBase: 0, sumInc: 0,
moreMultiplier: 1`. The summary silently excludes conditional/flagged/skill-tagged mods, so
at a glance it looks like *nothing* applies.

**Impact.** Nearly produced the conclusion "none of your increased damage is active." Only
manual per-entry inspection revealed the truth (most increases are real but condition-gated).

**Requests.**
- Either evaluate the summary **in the current calc context** (so it matches what the active
  skill actually receives), or clearly label it as "unconditional totals only — N
  conditional/flagged entries excluded."
- Provide an "as-applied-to-this-skill" mode that sums what the *main skill* actually gets.

## P1-2 — Modifier condition tags are opaque (no human-readable gate)

**Symptom.** Conditional mods came back tagged only `["Condition"]` or `["ActorCondition"]`
with no indication of *which* condition. To learn that Crashing Wave's +25% needs "crit in
the past 8s" and Killer Instinct's +40% needs "Full Life," each tree node's stat text had to
be looked up separately via `gui_search_passives`.

**Impact.** Turned "which buffs are off and could be on?" into ~6 extra lookups and
cross-referencing.

**Request.** Include a resolved `conditionName`/`gate` (e.g. `"conditionFullLife"`,
`"conditionCritInPast8Sec"`) and its current truth value on each conditional mod entry, so
the consumer can map a damage chunk → the config toggle that turns it on, directly.

## P1-3 — No hit-damage breakdown for the most important stat

**Symptom.** `gui_explain_stat{stat:"TotalDPS"}` returned only `avg × attack rate`.
`gui_explain_stat{stat:"AverageDamage"}` returned `"no per-stat breakdown recorded"`. The one
number the whole review hinged on — the hit — had no derivation. We reverse-engineered it
through several `gui_query_mods` calls.

**Request.** Give `AverageDamage`/hit a real Calcs-tab-style breakdown: base (weapon /
spell) → added flat by type → conversions → increased → more → crit-weighting. This is the
single most valuable explain target for "why is my damage X?"

## P1-4 — `hit.byType` is empty for Earthshatter even on the correct part

**Symptom.** `gui_explain_skill` returned `hit.byType: []` on **both** skill parts, despite a
non-zero average. Per-damage-type rows never populated for this skill.

**Impact.** Looked like a calc failure and fed the "stats are misrepresented" suspicion.
Aggregate DPS was correct, so the bug is cosmetic — but it actively erodes trust.

**Request.** Populate `byType` for slam / multi-part skills, or, if a part genuinely has no
direct hit, say so explicitly (`byType: [], note: "this part deals no direct hit"`) instead
of returning an ambiguous empty array.

---

## P2-1 — Added-flat-damage is hard to locate

`gui_query_mods{mod:"MaxPhysicalDamage"}` showed only Ryslatha's more/less multiplier; the
rings' "Adds 7–13 Physical Damage to Attacks" lives under a different mod name and never
surfaced. A `gui_explain_hit_sources` helper (weapon base + all added flat by type, with
sources) would make "what is the hit built from?" a single call.

## P2-2 — `gui_search_passives` allocated-vs-suggested is easy to misread

Default search returns nearby **unallocated** suggestions (`alloc: false`). These were
momentarily conflated with allocated nodes. `gui_get_build{includeNotables:true}` is the
correct source of truth, but it only returns *notables*. Requests: (a) make `alloc` more
prominent / allow an `allocatedOnly` filter; (b) let `includeNotables` optionally include
allocated **normal** nodes too, so "what weapon-type/keyword nodes do I actually have?" is
answerable without trusting a suggestion list.

## P2-3 — Surface "conditional buffs currently inactive"

A derived helper listing damage multipliers that are **off but toggleable** (with their
config var and magnitude) would have produced the "30k idle → 37.5k in combat" story in one
call, instead of inferring it from raw mods. High value for honest DPS reporting.

---

## What worked well (keep)

- `gui_set_config` round-tripping refreshed stats immediately — made the
  idle-vs-combat-vs-boss comparison fast and trustworthy once the right vars were known.
- `gui_get_config{query:…}` discovery (crit/rage/stun) surfaced exact var names and labels,
  which kept config changes honest (we could decline to fake rage/daze).
- `gui_get_items` / `gui_get_skills` data was accurate; the gem levels and the Parry-only
  jewel line were all correctly represented — the issues above are about *surfacing* and
  *explaining*, not data correctness.

---

## Skill & workflow improvements (not tool bugs — guidance gaps)

Some of this session's wrong turns weren't tool faults at all; the **skill** failed to
guard against a known failure mode. These are concrete additions for the `poe2-build` skill
reference files. They'd help even after the tools are fixed, and several are pure process.

### S-1 → `references/troubleshooting.md`: "Suspiciously low DPS" checklist

Before ever telling a user their build is weak / mis-built, rule out measurement artifacts
**in this order**, because each one bit us this session:
1. **Skill part.** For multi-part skills (slams, traps, multi-stage), confirm which part the
   DPS reflects. Earthshatter's *slam* read 8.2k; the *shatter* read 30.4k (3.7×). A
   surprisingly low number is a skill-part check before it is a verdict.
2. **Conditional buffs / config.** Idle config has crit-recently, stun/daze, rage, and
   enemy-boss toggles off. Read the build's conditional damage nodes, set the ones the build
   genuinely triggers, then re-read. (Idle 30.4k → realistic 37.5k here.)
3. **Enemy toggle.** `enemyIsBoss = None` measures vs a white mob; set a real benchmark.

Only after all three should "the build itself is weak" be on the table.

### S-2 → `references/tool-cookbook.md`: `gui_search_passives` returns SUGGESTIONS

Add an explicit gotcha: by default this tool returns nearby **unallocated** nodes
(`alloc: false`) as candidates — they are NOT on the tree. (This session described searched
quarterstaff nodes as "allocated" and built a whole false thesis on it.) Rules:
- To state what's **on** the tree, use `gui_get_build{includeNotables:true}` or pass
  `includeAllocated:true` and **check the `alloc` flag on every node** before describing it.
- Never characterize a build's tree from a default `gui_search_passives` result.

### S-3 → `references/tool-cookbook.md` (or goal-elicitation): ascendancy points

`ascendancyTotal` is the **cap**, not what's unlocked. Don't recommend "spend your free
ascendancy points" from `ascendancyRemaining` alone — **ask the user whether their trials
are done** first. (We recommended spending 4 points that weren't unlocked.)

### S-4 → `references/build-order.md` / skill body: lead with verification, not alarm

When the opening read looks alarming, the first user-facing move should be a verification
pass, not a diagnosis. "This number looks off — let me confirm the skill part and config
before concluding" beats "your DPS is critically low." Cheap to do, and it preserves trust
when the alarm turns out to be an artifact (as it did here, twice).

### S-5 → skill body: separate "tool data" from "my interpretation"

When a value surprises you, distinguish *the tool reported X* from *I concluded Y*. This
session the data was correct every time; the errors were interpretation (alloc flag, ascendancy
cap, skill part). Owning that precisely — rather than blaming "inaccurate tools" — is the
correct response when a user pushes back, and it's what let us find the real (skill-part) issue.

---

## TL;DR for the maintainer

The data layer is sound; the **explanation layer** is what misled. Two changes would have
prevented both wrong recommendations outright:

1. **Expose skill-part** (read + set) on the DPS tools. (P0-1)
2. **Separate unlocked-but-unspent from locked ascendancy points.** (P0-2)

And three would have made the diagnosis fast instead of manual: condition names on mods
(P1-2), a real hit breakdown (P1-3), and a context-aware `query_mods` summary (P1-1).
