# Build Context — Earthshatter "Turbo Blender" Martial Artist

> Personal PoE2 build context doc. Based on **Ulf's Earthshatter TURBO Blender** (Mobalytics, patch 0.5), adapted to the current live Path of Building 2 state. Use this as the reference for what the build *is* and *why* each piece exists.

## Identity (live PoB2)

| | |
|---|---|
| **Class / Ascendancy** | Monk → **Martial Artist** |
| **Main skill** | Earthshatter (socket group 4) |
| **Level** | 81 (104/104 passives, 4/8 ascendancy used) |
| **Combined DPS** | ~40,950 |
| **Life / ES / Mana** | 1,478 / 2,598 / 590 |
| **Total EHP** | ~48,700 |
| **Crit** | 47.3% chance, ~4.02 crit damage bonus multiplier |
| **Attack speed** | ~3.92/s |
| **Resistances** | Fire 77 / Cold 75 / Lightning 75 / Chaos 49 |

> Note: ascendancy is only 4/8 used and Chaos res (49) is below the others — both are headroom for upgrades.

## Core fantasy

A "walking tornado": stack attack/skill speed, slam **Earthshatter** for raw physical damage, and let an automated **freeze → shatter → explosion** chain delete everything around you. Movement and clear come from **Boneshatter** dashing you through packs; bossing comes from Earthshatter + the self-feeding **Madness** damage stack. Intentionally simple to pilot.

## The three signature interactions

These are the heart of the build — everything else supports them.

### 1. Physical → Freeze (no cold investment)
- **Vestige of Darkness** (helmet): *"Physical damage from Hits Contributes to Chill Magnitude and Freeze Buildup."* This lets pure **physical** Earthshatter hits chill and freeze enemies without scaling any cold/ailment stats.
- Result: enemies around you are kept permanently chilled/frozen, which both slows them (defense) and sets up the shatter engine.

### 2. Freeze → Shatter → Explosion (the "blender")
- **Herald of Ice** detonates frozen enemies you shatter, dealing cold area damage that chains through packs.
- **Blasphemy** + the **Repulsion** trigger curse + **Magnified Area** spread the curse/explosion radius so packs blow up all around you.
- **Living Lightning II** (socketed in the Blasphemy/curse group) loops independently for near-AFK clear in dense content (breach/ritual).

### 3. Madness stacking (self-feeding boss damage + defense)
- **Sadist's Mercy** (mace): *"Hits inflict 3 Gruelling Madness"* and *"Enemies in your Presence have additional Power equal to their Gruelling Madness."*
- **Harbinger of Madness** (granted by the same mace at lvl 18, also hand-socketed with supports) converts stacked madness into escalating damage the longer a fight lasts.
- Gruelling Madness also acts like a Temporal-Chains-tier slow → a defensive layer on bosses.

## Skills & support setup (live)

**Earthshatter** — MAIN (group 4)
`Rapid Attacks II` · `Branching Fissures II` · `Aftershock II` · `Brutality III`
→ Pure physical slam. Brutality (more phys, no elemental) keeps damage all-physical so it feeds freeze + mana leech. Aftershock/Branching Fissures add extra slam instances and coverage.

**Boneshatter** — mobility / rage
`Rapid Attacks III` · `Rage III` · `Efficiency II` · `Knockback`
→ Dash-forward traversal, generates Rage, knocks back to create space.

**Harbinger of Madness** — madness payoff (also granted by weapon)
`Magnified Area II` · `Bleed IV` · `Heft` · `Armour Break III`
→ Scales with enemy madness stacks; Armour Break + Bleed add phys pressure.

**Blasphemy (curse aura) + Repulsion** — the pack-detonation engine
`Living Lightning II` · `Magnified Area II` · `Ritualistic Curse`
→ Aura'd curse that triggers explosions on hit; Living Lightning auto-loops.

**Herald of Ice** — shatter explosions
`Magnified Area II` · `Elemental Armament II` · `Elemental Focus` · `Cold Penetration`
→ Detonates shattered frozen enemies; the cold-damage scaling here is the *only* place cold is invested.

**Sniper's Mark** — charge / sustain engine
`Charged Mark` · `Cooldown Recovery II` · `Charge Profusion II` · `Mark of Siphoning II`
→ Maintains charges and siphon sustain.

**Hollow Focus** (buff, Martial Artist) — `Cooldown Recovery II` · `Close Combat II` · `Concentrated Area` · `Heft`

**Refutation** — defensive burst — `Prolonged Duration II` · `Cooldown Recovery II`

**Remnants of Kalguur** (sustain) — `Harmonic Remnants II` · `Remnant Potency I`

**Charge Regulation** — charge management (persistent).

## Passive tree — keystone & key notables

- **Dance with Death** (Keystone) — the linchpin: big multiplicative attack speed for wielding a **single one-hand mace, no shield**. Defines the one-hander requirement.
- Speed/attack cluster: *Tenfold Attacks, Acceleration, True Strike, Flow Like Water, Deep Trance*.
- Crit/damage: *Killer Instinct, Careful Assassin, Deadly Force, Heartbreaking, For the Jugular, Moment of Truth*.
- Slam/phys: *Way of the Stonefist, Forcewave, Crashing Wave, Struck Through, Heft-adjacent nodes*.
- Defense: *Enhanced Reflexes, Spectral Ward, Heartstopping, Beastial Skin, The Hollowkeeper, Stupefy, Mindful Awareness*.
- Monk/Hollow theme: *Hollow Focus Technique, First Principle of the Hollow, First Teachings of the Keeper, Chakra of Thought*.

## Gear & uniques — role of each piece

| Slot | Item | Why it's here |
|---|---|---|
| Weapon | **Sadist's Mercy** (Flanged Mace) | Madness engine + grants Harbinger of Madness. Single one-hander enables Dance with Death. |
| Helmet | **Vestige of Darkness** (Tenebrous Crown) | Phys-hits-contribute-to-freeze → the whole freeze chain. Also Blind + Bodach in Presence. |
| Body | Eagle Suit (rare) | Evasion/ES hybrid, life, cold res, deflection. |
| Gloves | Torment Talons (rare) | +1 melee, extra phys as extra phys, low-life mitigation, evasion/ES per level. |
| Boots | Spirit Trail (rare) | 30% move speed, big evasion, res. |
| Amulet | Lapis (rare), anoint *Serrated Edges* | Spirit (for auras/heralds), ES, res. |
| Ring 1 | Honour Grip (Ruby) | Flat phys + fire to attacks, res. |
| Ring 2 | Dragon Circle (Breach) | **Mana leech (phys)** — mandatory sustain — + chaos res. |
| Belt | **Ryslatha's Coil** | Huge max phys attack damage (raises top-end slam). |
| Charms | Nascent Hope (Thawing), Beira's Anguish (Dousing) | Anti-freeze, anti-ignite + ES recharge / ignite ground. |
| Flask 1 | Bubbling Ultimate Life of the Doctor | Instant recovery. |
| Flask 2 | **Lavianga's Spirits** | Constant mana effect (no-use sustain). |
| Jewels | Heart of the Well (Diamond), Fulgent Delirium (Emerald) | Skill/attack speed, %dmg-as-cold, crit/attack damage. |

## Sustain model

Damage is kept **all physical** specifically so that **physical-damage mana leech** (Dragon Circle ring + weapon's mana leech) sustains the high attack-speed spam. Lavianga's gives passive mana. This is why Brutality is used and why elemental scaling is avoided outside Herald of Ice.

## Defensive layers

1. **Permanent freeze/chill** on surrounding enemies (Vestige) — they barely act.
2. **Gruelling Madness** slow from the mace (Temporal-Chains-tier).
3. **Evasion + ES hybrid** stacking (Eagle Suit, Torment Talons per-level, deflection nodes).
4. **Refutation** defensive burst window.
5. Anti-freeze / anti-ignite charms; Blind on enemies in Presence.

## Live config (modified from default)

- "Always on Full Life" = **on** (enables low-life/full-life conditional mods).
- Enemy Level = 68, Enemy is Boss = **None** (currently tuned to clear-speed, not boss, numbers).
- Various act/quest passive rewards allocated.

> To read boss DPS, flip `enemyIsBoss` to Pinnacle in PoB2.

## Known gaps / upgrade headroom

- Life is low (1,478) — build leans on ES (2,598) + evasion + freeze-lock rather than life.

## Possible upgrade paths

All numbers below were measured live in PoB2 against the baseline (**40,950 DPS / 48,695 EHP / 104 of 104 passives**), then reverted. DPS for conditional nodes was measured against a realistic clear baseline — enemy **Frozen / Chilled / Blinded** toggles enabled, since Vestige of Darkness keeps packs in all three states (toggles reverted afterward). The build has **0 spare points**, so any add must be funded by levelling (1 pt/level) or refunding from the "Least Useful" lists.

### 1. Next Best DPS Nodes (to add)

Ranked by DPS per point.

| Node | id | Cost | DPS Δ | DPS/pt | Notes |
|---|---|---|---|---|---|
| **Thin Ice** | `19722` | 2 pts | 40,950 → **50,640 (+23.7%)** | ~11.9% | 50% dmg vs **Frozen** + 20% Freeze Buildup. Clear only — bosses resist freeze. |
| **Herald Damage** | `56847` | 1 pt | 40,950 → 43,279 (+5.7%) | ~5.7% | 12% dmg while affected by a Herald — *always on*. **Two of these exist** nearby. |
| Stylebender | `60138` | 3 pts | 40,950 → 47,732 (+16.6%) | ~5.5% | 25% phys + 30% Armour Break on ailmented targets. Works on bosses. |
| Chakra of Impact | `25362` | 4 pts | 40,950 → 49,670 (+21.3%) | ~5.3% | 20% Attack Damage + combo scaling; path is attack-dmg filler. Works on bosses. |
| Imbibed Power | `50912` | 8 pts | 40,950 → 44,197 (+7.9%) | ~1.0% | 25% Damage + 6% AS during any Flask Effect — always on (Lavianga's). |
| Versatile Arms | `4238` | 9 pts | 40,950 → 44,048 (+7.6%) | ~0.8% | 6% AS (1H) + 10 Str/Dex + **jewel socket**; 15% accuracy is wasted (already 100% hit). |
| Stimulants | `7163` | 9 pts | +1,355 on top of Imbibed (→45,552) | low | 16% AS during any Flask Effect + **jewel socket**. Pairs with Imbibed Power. |
| First Approach | `29527` | 4 pts | no change | — | 80% dmg vs **full-life** enemies — clear one-shot tech only; PoB shows 0, nothing on bosses. **Skip.** |

**Best buys:** Thin Ice + both Herald Damage nodes ≈ **+33–35% for ~4–5 pts** (clear). Chakra of Impact / Stylebender for unconditional damage that also works on bosses.

**Flask-node caveat:** *Arcane Mixtures* ("if you've **used** a Mana Flask recently") and *Warding Potions* ("when you **use** a Mana Flask") never trigger — Lavianga's *cannot be Used*. Only *"during/while in effect"* wordings work for this build.

### 2. Next Best EHP Nodes (to add)

Ranked by EHP per point. Deflection and %-evasion scale hard here off the ~11k evasion pool.

| Node | id | Cost | EHP Δ | EHP/pt | Notes |
|---|---|---|---|---|---|
| **Inner Faith** | `30562` | 4 pts | 48,695 → ~58,060 (+19%) | ~2,341 | 20% evasion + 20% ES + 25% reduced curse effect. Most EHP/pt found. |
| **The Wild Cat** | `22811` | 3 pts | 48,695 → 53,861 (+10.6%) | ~1,722 | Deflection = 12% of evasion + **40% evasion while moving** + 10 Dex. |
| Evasion + Energy Shield | `18314` | 1 pt | 48,695 → 50,307 (+3.3%) | ~1,612 | 12% evasion + 12% ES. Many identical nodes sit at pathDist 1 — repeatable. |

### 3. Least Useful DPS Nodes (safe to refund)

Allocated leaf notables, ranked by smallest DPS loss (each costs ~0 EHP). Refund these to fund DPS/EHP adds without cascading.

| Node | id | DPS lost | Notes |
|---|---|---|---|
| **Tenfold Attacks** | `25971` | −1.9% (−790) | Also −1.9% attack speed. Cheapest DPS refund. |
| True Strike | `61601` | −3.7% (−1,531) | 20% crit chance. |
| Heartbreaking | `13407` | −5.0% (−2,029) | 25% crit damage. Most costly of the three. |

### 4. Least Useful EHP Nodes (safe to refund)

Allocated defensive leaves, ranked by smallest EHP loss (each costs **0 DPS**). Best source of points for DPS adds like Thin Ice.

| Node | id | EHP lost | Notes |
|---|---|---|---|
| **Evasion + Energy Shield** | `15975` | −3,123 (−6.4%) | 12% evasion + 12% ES normal. Cheapest EHP refund. |
| Beastial Skin | `59720` | −4,375 (−9.0%) | 100% increased evasion from body armour. |
| Spectral Ward | `34324` | −4,579 (−9.4%) | +1 max ES per 12 item evasion; big ES source. |

> **Do not refund** `39595` Way of the Stonefist — it transforms your gloves into Fists of Stone (Torment Talons depends on it). It is a leaf, so it *looks* safe, but removing it breaks the gloves.

### Trade ratios & recommended swaps

- **DPS for points:** refunding a DPS leaf costs ~2–5% DPS/pt; the best adds (Thin Ice ~11.9%/pt, Herald ~5.7%/pt) far exceed that — net DPS gain even after self-funding.
- **EHP for points:** moving a point from a DPS leaf to an EHP node costs ~2% DPS and buys ~3.3–4.7% EHP — strongly favours tankiness.
- **Least-loss path to Thin Ice (clear DPS, keep offence):** refund `15975` + `59720` (≈ −7k EHP, 0 DPS) → allocate Thin Ice (+23.7% clear DPS).
- **Tankiness on a budget:** refund `25971` (Tenfold, −1.9% DPS) → one `18314` (+3.3% EHP). Repeatable.

> Reminder: Thin Ice / First Approach gains are clear-only (frozen / full-life packs). Stylebender, Chakra of Impact, Imbibed Power, and all EHP nodes apply on bosses too. Build is currently tuned for clear (`enemyIsBoss: None`).

## Sources

- [Ulf's Earthshatter TURBO Blender — Mobalytics](https://mobalytics.gg/poe-2/builds/earthshatter-turbo-blender-ulfhednar)
- [Build mirror (translated) — kami-labs](https://kami-labs.fr/en/path-of-exile-2/builds-path-of-exile-2/build-moine-ulf-s-earthshatter-turbo-blender-saison-5/)
- [Turbo Blender 2.0 — YouTube](https://www.youtube.com/watch?v=Qz-7_ivRVJg)
- Live build read from Path of Building 2 via the pob2 MCP bridge.
