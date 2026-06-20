# Reference: PoB2's existing live-PoE integration

A technical map of the Path of Exile **account** and **trade** machinery already
built into PoB2's GUI source — OAuth, character import, trade search/fetch, pricing,
and rate limiting. This is the "what exists today" companion to
[`PROPOSAL-live-poe-tools.md`](./PROPOSAL-live-poe-tools.md) (the "what we'd build"
doc). None of this is exposed to the MCP yet; it's documented here so the MCP work
can wrap it instead of reimplementing it.

All line numbers verified against source on the `bri64-mcp` branch (2026-06-19).

---

## 1. The async networking model (read this first)

Everything below is **asynchronous and callback-driven**. PoB never blocks on HTTP:

- All requests go through `launch:DownloadPage(url, onComplete, opts)` (see
  `PoEAPI.lua:36,121,152`, `TradeQueryRequests.lua:67,515`). The `onComplete(response,
  errMsg)` callback fires on a **later frame**.
- The OAuth browser redirect runs as a sub-script: `LaunchSubScript(...)`
  (`PoEAPI.lua:100`) with a localhost listener in `src/LaunchServer.lua`.

Implication for MCP: the bridge handler (`src/Modules/MCPBridge.lua`) returns
synchronously within one frame and **must never block** (`MCPBridge.lua:17`). Any MCP
tool wrapping these features needs an **async job pattern** (start → poll → done).
See §2 of the proposal.

---

## 2. OAuth2 authentication — `src/Classes/PoEAPI.lua`

PKCE flow against `pathofexile.com`. Client id is hardcoded `pob`.

| Concern | Detail | Location |
|---|---|---|
| Base API host | `https://api.pathofexile.com` | `PoEAPI.lua:19` |
| Scopes | `account:profile`, `account:leagues`, `account:characters`, `account:trade` | `PoEAPI.lua:5` |
| Authorize URL | `https://www.pathofexile.com/oauth/authorize?client_id=pob&response_type=code&scope=%s&state=%s&code_challenge=%s&code_challenge_method=S256` | `PoEAPI.lua:93` |
| Token URL | `https://www.pathofexile.com/oauth/token` (auth-code + refresh-token grants) | `PoEAPI.lua:36,121` |
| Browser redirect | local listener, `LaunchSubScript` opens consent URL | `PoEAPI.lua:100`, `src/LaunchServer.lua` |

**Key functions:**
- `PoEAPIClass:FetchAuthToken(callback)` — `:81` — full first-time consent flow.
- `PoEAPIClass:ValidateAuth(callback)` — `:27` — checks expiry, auto-refreshes.
- `PoEAPIClass:DownloadWithRefresh(endpoint, callback)` — `:143` — wraps a call,
  transparently refreshes the token and retries once on auth failure.
- `PoEAPIClass:DownloadWithRateLimit(policy, url, callback)` — `:181` — gates every
  call through the rate limiter.
- `PoEAPIClass:UpdateMain()` — `:73` — persists tokens to PoB settings.

**Token persistence:** `main.lastToken`, `main.lastRefreshToken`, `main.tokenExpiry`
(saved via `main:SaveSettings()`). Requests attach `Authorization: Bearer <token>`.
→ MCP can reuse a token the user authorized once in the GUI; **never return the token
over the bridge.**

---

## 3. Character import — `src/Classes/PoEAPI.lua` + `src/Classes/ImportTab.lua`

**Fetch layer (PoEAPI):**
- `DownloadCharacterList(realm, callback)` — `:205` → `GET /character[/<realm>]`
  (policy `character-list-request-limit-poe2`). Returns `{ characters: [{ name, class,
  league, level, ascendancy, experience }] }`.
- `DownloadCharacter(realm, name, callback)` — `:214` → `GET /character[/<realm>]/<name>`
  (policy `character-request-limit-poe2`). Returns `{ character: { passives, equipment,
  skills, jewels, level, ... } }`.

**Parse/apply layer (ImportTab):**
- `ImportTabClass:DownloadCharacterList()` — `:427` — UI-driven list fetch.
- `ImportTabClass:DownloadCharacter(callback)` — `:587` — fetch + hand parsed char to
  callback. Granular variants: `DownloadPassiveTree()` `:637`, `DownloadItems()` `:643`.
- Import builds the live spec: passive hashes → `spec:ImportFromNodeList()`, weapon-set
  nodes, attribute overrides, quest-reward stats; equipment → PoB item bases + mods;
  skills → gems/supports/spectres/companions with level/quality/links.

**Realm:** only PoE2 is wired up — `realmList` in `ImportTab.lua:16`:
`{ label="PoE2", realmCode="poe2", hostName="https://www.pathofexile.com/" }`.

**Note for MCP:** import logic is currently entangled with the Import **tab's** UI
state machine. A bridge tool likely needs a small refactor to call "fetch + parse +
apply" without the tab being active (proposal OQ-B).

---

## 4. Trade search & pricing

### 4a. Weighted query generation — `src/Classes/TradeQueryGenerator.lua`

The "find best upgrades for this slot" engine. Ranks each candidate mod by its **real
contribution to this build's DPS/EHP** (clone item, add mod, recalc, measure delta).

- `StartQuery(slot, options)` — `:780` — options include `statWeights`
  (`"FullDPS"`/`"TotalEHP"`), `maxPrice`, `maxPriceType`, `maxLevel`, sockets.
- `GenerateModData(...)` — `:359` / `GenerateModWeights(modsToTest)` — `:648` — weight
  calc.
- `ExecuteQuery()` — `:885` / `FinishQuery()` — `:932` — emit the trade JSON
  (`type_filters`, `trade_filters.price {option,max}`, `req_filters`,
  `equipment_filters`, weighted `stats` filters; **max 35 filters**).

### 4b. Search + fetch HTTP — `src/Classes/TradeQueryRequests.lua`

Trade API **v2** at `https://www.pathofexile.com/`:

| Endpoint | Purpose | Location |
|---|---|---|
| `api/trade2/search/{realm}/{league}` (POST) | submit query → `{id, total, result:[hashes]}` | `:205,207` |
| `api/trade2/fetch/{hashes}?query={id}` (GET) | item details, 10 hashes/batch | `:246,253` |
| `api/trade2/search/{realm}/{league}/{id}` (GET) | re-open a saved search | `:493` |
| `api/trade2/data/leagues` (GET) | league list | `:513,516` |

**Key functions:** `SearchWithQuery` `:84`, `SearchWithQueryWeightAdjusted` `:104`
(binary-searches the weight floor when results clip at 10k), `PerformSearch` `:205`,
`FetchResults` `:246`, `FetchLeagues` `:513`, `buildUrl` `:542`. Each fetched listing
yields price `{amount, currency, type}`, full item text, seller, and `whisper`.

### 4c. Pricing / currency — `src/Classes/TradeQuery.lua`

- `PullPoENinjaCurrencyConversion(league)` — `:113` → poe.ninja PoE2 economy:
  `https://poe.ninja/poe2/api/economy/exchange/current/overview?type=Currency&league=<league>`
  (`:124`), cached `<league>_currency_values.json`, ~1 req/hour.
- `ConvertCurrencyToDivs(currencyId, amount)` — `:104` — normalize any budget to
  divine (poe.ninja's base unit).
- `PullLeagueList()` — `:69` → `api/leagues?type=main&compact=1`.
- Sorting modes (`SortFetchResults` `:878`): Weight, StatValue, StatValuePrice
  (`weight - 0.1*log10(price)`), Price.

### 4d. Mod → trade-stat-ID mapping

- `src/Classes/TradeHelpers.lua` — `findTradeHash()`, `getTradeStats()`.
- `src/Data/TradeSiteStats.lua` — auto-generated from `api/trade2/data/stats`; maps
  PoB mod text → `explicit.stat_*` / `implicit.*` / `pseudo.*` ids. Handles inverted
  mods and special cases (curses, arrows).

---

## 5. Rate limiting — `src/Classes/TradeQueryRateLimiter.lua`

Reusable limiter; **all** account/trade calls route through it (never bypass it).
Tracked policies (`:54-57`): `trade-search-request-limit`, `trade-fetch-request-limit`,
`character-list-request-limit-poe2`, `character-request-limit-poe2`. Limits are parsed
live from `x-rate-limit-*` response headers (`:77-94`); 429 → backoff honoring
`retry-after`. Applies a safety margin so external requests don't trip PoB's budget.

---

## 6. File map (quick index)

| File | Role |
|---|---|
| `src/Classes/PoEAPI.lua` | OAuth, token refresh, account/character fetch, rate-limit gating |
| `src/LaunchServer.lua` | localhost OAuth redirect listener |
| `src/Classes/ImportTab.lua` | character import UI + parse/apply into the build; `realmList` |
| `src/Classes/TradeQueryGenerator.lua` | weighted query generation (mod → build-impact weights) |
| `src/Classes/TradeQueryRequests.lua` | trade2 search/fetch HTTP, weight-adjusted search |
| `src/Classes/TradeQuery.lua` | trade UI, currency conversion, league list, result sorting |
| `src/Classes/TradeQueryRateLimiter.lua` | rate-limit state machine (header-driven) |
| `src/Classes/TradeHelpers.lua` | mod ↔ trade stat-ID lookup |
| `src/Data/TradeSiteStats.lua` | generated trade stat definitions |

---

## 7. Bridge integration pattern (for when we wrap this)

MCP tools reach the live GUI through the bridge — request/response is
newline-delimited JSON over TCP (`127.0.0.1:8843`):

```
Request:  {"id":N,"method":"<name>","params":{...}}
Response: {"id":N,"ok":true,"result":{...}}  |  {"id":N,"ok":false,"error":"..."}
```

Adding a tool = one Lua handler + one Node registration:

1. **Lua** (`src/Modules/MCPBridge.lua`): add `function methods.myMethod(build, params)`
   to the `methods` table; return a JSON-serializable table; throw `error("...")` on
   failure (caught by `Bridge:handleLine`'s `pcall`). Mutators call
   `AddUndoState()`, set `build.buildFlag = true`, set `Bridge.lastUndoScope`, and
   return `recalcAndRead(build, params.stats)`.
2. **Node** (`mcp/src/index.ts`): `server.tool("myMethod", "desc", { <zod> }, p =>
   callBridge("myMethod", p))`.

**The catch (§1):** these handlers run within a single frame and can't block. The
account/trade features are async, so wrapping them requires the start/poll/done job
primitive described in the proposal — not the plain synchronous handler shape above.
