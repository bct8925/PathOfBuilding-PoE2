# Proposal: Live-PoE Integration Tools for the PoB2 MCP

Status: **investigation / design draft** (not yet scheduled). Scope: new MCP tools
that surface PoB2's existing **live Path of Exile 2 account + trade** machinery —
character import, item search within budget/criteria, and pricing.

This is explicitly out of the current v1 scope (`mcp/REQUIREMENTS.md` lists
"external imports: PoB codes, account character import, trade" as deferred). This
doc is the case for a v2 slice, what's already built, and what it would take.

> Companion doc: [`REFERENCE-pob-live-integration.md`](./REFERENCE-pob-live-integration.md)
> — a verified technical map of the existing PoB account/trade code (endpoints,
> functions, file:line refs) that these tools would wrap.

---

## 1. What PoB2 already has (we wrap, we don't build)

The good news: **the hard parts already exist in PoB's GUI code.** OAuth, rate
limiting, retry/backoff, mod→trade-stat-ID mapping, weighted-query generation, and
full item/character parsing are all implemented and battle-tested in the desktop
app. New MCP tools are mostly *thin bridge handlers that drive existing classes*.

| Capability | Implemented in | Entry points |
|---|---|---|
| OAuth2 PKCE login + token refresh | `src/Classes/PoEAPI.lua`, `src/LaunchServer.lua` | `PoEAPIClass` (client_id `pob`, scopes incl. `account:characters`, `account:trade`) |
| Character **list** fetch | `PoEAPI.lua` | `DownloadCharacterList(realm, cb)` → `api.pathofexile.com/character` |
| Character **detail** import (tree/items/skills/jewels) | `src/Classes/ImportTab.lua` | `DownloadCharacter(realm, name, cb)` + the tab's import/build logic |
| Trade **search** (weighted) | `src/Classes/TradeQueryGenerator.lua` | `StartQuery(slot, options)`, `FinishQuery()` |
| Trade **search/fetch** HTTP | `src/Classes/TradeQueryRequests.lua` | `SearchWithQueryWeightAdjusted()`, `FetchResults()`, `FetchLeagues()` |
| Mod → trade stat-ID mapping | `src/Classes/TradeHelpers.lua`, `src/Data/TradeSiteStats.lua` | `findTradeHash()`, `getTradeStats()` |
| Currency / budget conversion | `src/Classes/TradeQuery.lua` | `PullPoENinjaCurrencyConversion()`, `ConvertCurrencyToDivs()` (poe.ninja PoE2 economy API) |
| Rate-limit state machine | `src/Classes/TradeQueryRateLimiter.lua` | parses `x-rate-limit-*` headers; policies for search/fetch/character |

API surface already used: `api/trade2/search/{realm}/{league}`,
`api/trade2/fetch/...`, `api/trade2/data/stats`, `api/trade2/data/leagues`,
`api.pathofexile.com/character[/poe2]/...`, plus poe.ninja PoE2 economy for prices.

---

## 2. The one real architectural problem: async vs. the synchronous bridge

Every network feature above is **asynchronous and callback-driven**. PoB issues
HTTP via `launch:DownloadPage(url, onComplete, ...)` / `LaunchSubScript`, and the
result lands on a later frame (pumped from `main:OnFrame` → `PumpMCPBridge`).

The MCP bridge, by contrast, is **synchronous-per-frame**: `Bridge:handleLine`
runs a handler and returns a result in the same frame; the Node client awaits one
response per request (`mcp/src/bridge/socket.ts`). A handler **must never block**
(`MCPBridge.lua:17` says so explicitly — it would freeze the GUI).

So a trade/import handler cannot just "call the API and return the result." We need
an **async job pattern** on the bridge:

```
  start  → handler kicks off DownloadPage, stores a job in a pending table,
           returns { jobId, status: "pending" } immediately (same frame)
  poll   → Node calls a `jobStatus` method; handler returns
           { status: "pending" | "done" | "error", result?, error? }
           the download's onComplete callback fills result on a later frame
  done   → Node resolves the tool call with the result, drops the job
```

The Node side wraps this as a single `await`-able tool call that polls the bridge
every ~250ms up to a timeout. This is a **new, reusable bridge primitive** —
roughly one job-table + two methods (`*.start` / `job.poll`) — that all of section
3 builds on. It also makes the *existing* `gui_optimize` story nicer for long runs.
This primitive is the single biggest piece of net-new work.

Second constraint: **OAuth is interactive.** First-time login opens a browser
(`LaunchServer.lua` localhost redirect) and needs a human to consent. The MCP can't
complete that headlessly. Practical answer: the user authorizes **once in the PoB
GUI** (existing Import tab button); the token is persisted in PoB settings
(`main.lastToken` / `lastRefreshToken` / `tokenExpiry`) and **auto-refreshes**, so
MCP tools reuse it silently thereafter. MCP exposes an `account_auth_status` check
and, if signed out, returns a clear "authorize in PoB's Import tab" message rather
than trying to drive the browser flow itself.

---

## 3. Proposed tool sets

Naming follows the existing convention (`gui_*` for live-GUI-bridged tools). All of
these are bridge handlers in `src/Modules/MCPBridge.lua` + tool registrations in
`mcp/src/index.ts`, same pattern as the current 35 tools.

### A. Live character / account (read-from-game)

| Tool | Does | Drives |
|---|---|---|
| `gui_account_status` | Report auth state, account name, selected realm, token expiry; tells the user to authorize in PoB if signed out. | `PoEAPI` token validate |
| `gui_list_characters` | List the account's characters (name, class/ascendancy, level, league). Read-only; great for "analyze my actual character." | `DownloadCharacterList` |
| `gui_import_character` | Import a named character's tree+items+skills+jewels into the **live build** (replaces or as new build). The headline tool — "pull in my real character and tell me what to fix." | `ImportTab` import flow |
| `gui_compare_to_character` | Import to a scratch spec and diff vs. the current build (stat deltas, gear gaps) without clobbering work. | import + existing diff/stat read |

Why valuable: turns the MCP from "edit a planner" into "analyze the build I'm
actually playing." Pairs directly with the existing `gui_explain_*` tools.

### B. Trade search within criteria + budget (the requested feature)

| Tool | Does | Drives |
|---|---|---|
| `gui_find_upgrades` | For a given slot, run PoB's **weighted** query (rank mods by their real DPS/EHP contribution to *this* build), capped at a budget (`maxPrice` + currency), return top listings with price, mods, and the live stat gain if equipped. This is the marquee tool. | `TradeQueryGenerator:StartQuery` + `SearchWithQueryWeightAdjusted` + `FetchResults` |
| `gui_search_trade` | Explicit criteria search: base type, rarity, mod filters with min/max ranges, item level, sockets, budget, league/online status — without the weighting. "Find me a ring with ≥80 life, ≥30% fire res, under 2 div." | `TradeQueryRequests` with a hand-built query |
| `gui_price_item` | Price a specific item (equipped or pasted): find comparable listings → estimated market price in chaos/divine. | trade search + currency convert |
| `gui_trade_preview_upgrade` | Take a listing from a search result and compute the **exact** stat delta if equipped (temp-apply to a scratch item, recalc, revert) before the user commits a real-money trade. | existing item add/recalc/undo |

Budget handling is already solved: `trade_filters.price = { option, max }` in the
query, plus poe.ninja currency conversion so "budget" can be normalized to divine
regardless of the listing currency.

### C. Economy / pricing helpers

| Tool | Does |
|---|---|
| `gui_currency_rates` | Current chaos/exalted/divine exchange rates for the league (poe.ninja PoE2 economy), so the AI reasons about budgets in one unit. |
| `gui_list_leagues` | Available trade leagues for the realm (drives league selection in the tools above). |

### D. Workflow combinations (no new bridge code — just skill/orchestration)

These compose A–C and belong in the `poe2-build` skill, not as new handlers:

- **"Audit my real character"**: `gui_list_characters` → `gui_import_character` →
  `gui_explain_stat`/`gui_explain_skill` → narrate weakest layer.
- **"Budget upgrade pass"**: for each slot, `gui_find_upgrades` under a total
  budget → `gui_trade_preview_upgrade` to rank by stat-gain-per-divine → present a
  shopping list with whispers.
- **"Make it affordable"**: re-run `gui_optimize` constrained to mods that are
  cheap per the trade weights (feed price signal into the objective).

---

## 4. Effort / risk ranking

| Slice | Effort | Risk | Notes |
|---|---|---|---|
| Async job primitive (§2) | **M** | Med | Prerequisite for everything net-new; reusable. Touches bridge core. |
| `gui_account_status` / `gui_list_characters` | S | Low | Read-only; small handlers once auth reuse works. |
| `gui_import_character` | M | Med | Import logic exists but is entangled with `ImportTab` UI state; needs a headless-ish extraction of the import path. |
| `gui_find_upgrades` / `gui_search_trade` | **L** | Med-High | Highest value, most surface. Weighted-query gen is heavy; result fetch is async + rate-limited. Bulk of the work is shaping inputs/outputs, not new logic. |
| `gui_price_item` / `gui_currency_rates` / `gui_list_leagues` | S–M | Low | Mostly wrapping existing fetchers. |

Cross-cutting risks: **rate limits** (must respect PoB's limiter so we don't get
the user IP-throttled — reuse `TradeQueryRateLimiter`, never bypass it),
**ToS/automation** (read/search only; never auto-execute trades — always hand back a
whisper for the human), and **token security** (never return the OAuth token over
the bridge; keep it in PoB).

---

## 5. Recommendation

Two shippable phases:

1. **Phase A — "analyze my real character"** (smaller, lower risk): async job
   primitive + `gui_account_status` + `gui_list_characters` + `gui_import_character`.
   Immediately useful and validates the async pattern end-to-end.

2. **Phase B — "find upgrades within budget"** (the requested feature): build on the
   primitive with `gui_find_upgrades` + `gui_search_trade` + `gui_price_item` +
   currency/league helpers, and wire the workflows into the `poe2-build` skill.

Both reuse PoB's existing, maintained networking — we add bridge handlers and tool
registrations, plus one async primitive, rather than reimplementing any PoE API.

---

## 6. Open questions

- **OQ-A**: Confirm the OAuth token persisted by the GUI is readable/usable from the
  bridge context without re-consent (expected yes via `main.lastToken`, but verify
  the refresh path runs while the bridge pumps).
- **OQ-B**: Can `ImportTab`'s import path be invoked without the tab being the active
  view? May need a small refactor to separate "fetch+parse+apply" from UI state.
- **OQ-C**: Headless support — trade/import need PoB's `launch:DownloadPage`. Likely
  **GUI-only** (the headless wrapper stubs networking). Document these as live-GUI
  tools, like the rest of the `gui_*` surface.
- **OQ-D**: Result-size budgeting — trade fetches return verbose item JSON; cap and
  summarize (top N, key mods + price + whisper) to keep tool responses lean.
