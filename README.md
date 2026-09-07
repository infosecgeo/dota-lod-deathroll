# AI-LOD (`dota-lod-deathroll`)

Dota 2 Arcade custom game: modular LOD-style ability draft with death-draft, built on a **server-authoritative state machine**.

**Current milestone: V1.0 — full pool, polished LOD draft pipeline**

Flow:

```
WAITING → BAN (30s) → HERO_DRAFT (random 3×4 + rerolls) → ABILITY_DRAFT (3+1)
        → ULTIMATE_DRAFT (6 choices, confirm) → STRATEGY (buy items)
        → INTRODUCTION → SPAWN → PLAYING
        → per-player DEATH DRAFT (3 shared rerolls, multiple slot replacements)
        → GAME_OVER → victory/defeat, MVP + runner-up, final scoreboard
```

## Modules

```
AI-LOD
├── Game Flow      (draft → strategy → introduction → spawn → play → results)
├── Hero System    (full pool, bans, randomized category offers)
├── Ability System (basic/ult DB, blacklist, kit apply)
├── Draft System   (randomization, categories, rerolls, confirmation)
├── Player State   (skills, hero, deaths, rerolls)
└── UI             (ban / hero / ability / ultimate / death)
```

## Project layout

```
game/                          # copied to dota_addons/dota-lod-deathroll/
├── addoninfo.txt
├── scripts/
│   ├── config/                # KV: heroes, abilities, blacklist, balance
│   ├── npc/                   # engine herolist + draft pools
│   └── vscripts/
│       ├── addon_game_mode.lua
│       ├── gamemode.lua       # wires systems + ENABLE_LOD_DRAFT=true
│       ├── systems/           # state machine + managers
│       ├── libraries/
│       ├── draft/             # legacy reference scripts
│       └── mmr/
├── panorama/                  # foundation HUD + full draft UI
└── resource/
mmr-server/                    # optional local MMR API + dashboard
tools/                         # Python balance / AI analyzer (offline)
```

### Systems (`scripts/vscripts/systems/`)

| File | Role |
|------|------|
| `game_state.lua` | Central state machine (server authority) |
| `player_state.lua` | Per-player source of truth |
| `hero_manager.lua` | Full pool / ban / random 3×4 offers / spawn |
| `ability_manager.lua` | Ability DB + blacklist + kit application |
| `ban_manager.lua` | 30s hero ban |
| `draft_manager.lua` | Hero / ability / 2nd-ult draft |
| `reroll_manager.lua` | Category + death reroll budgets |
| `respawn_manager.lua` | Transactional multi-slot death draft (3 shared rerolls) |
| `match_results.lua` | Immutable final scoreboard and deterministic MVP ranking |
| `balance_manager.lua` | Power budget (reads `balance.kv`) |

Feature flag in `gamemode.lua`:

```lua
local ENABLE_LOD_DRAFT = true  -- V1.0 full LOD pipeline
```

## Roadmap

| Phase | Goal | Status |
|-------|------|--------|
| V0.1 / Phase 1–2 | Playable custom game + state machine | **done** |
| Phase 3 | 30s hero ban (server-validated) | **done** |
| Phase 4 | 3×4 hero pools + 1 reroll/category | **done** |
| Phase 5 | `abilities.kv` database | **done** |
| Phase 6–8 | 3 basic + 1 ult + spawn with kit | **done** |
| Phase 9 | 2nd ultimate (6 choices, confirm lock) | **done** |
| Phase 10–12 | Death draft, 3 rerolls, slot replace | **done** |
| Phase 13–14 | Python balance engine / AI analyzer | **done** |
| V1.0 | Full pool, polished Arcade build | **done** |

## Architecture rules

- **Server owns state.** Clients send intent (“ban Axe”); server validates.
- **No client-side RNG** for pools, bans, or rerolls.
- **No live AI in-match.** Python writes `scripts/config/*.kv`; Lua only reads.
- **One state machine** — no ad-hoc timers jumping phases without `GameState:Transition`.
- **Transaction-style picks** — validate → commit → lock.
- **All heroes available**, but each player only sees a **randomized 3×4 offer** (Strength / Agility / Intelligence × 4), with **1 reroll per category**.

## Hero pool (V1.0)

- **~118 heroes** enabled in `scripts/npc/herolist.txt`
- Categorized in `scripts/config/heroes.kv` and `scripts/npc/hero_categories.txt`
- Ban phase can ban any enabled hero
- Hero draft samples 4 random non-banned heroes per category **per player**

## Ability database

- `scripts/config/abilities.kv` — typed defs + `power_score`
- `scripts/npc/draft_abilities.txt` — Regular / Ultimate / ExtraUltimate / DeathReroll pools
- `scripts/config/blacklist.kv` — broken/intrinsic/transform exclusions
- `scripts/config/upgrade_abilities.kv` — explicit death-draft upgrade ownership and dependency rules

## Installation

### Prerequisites
1. Dota 2 (Steam)
2. **Dota 2 Workshop Tools** DLC
3. Node.js **22.5+** only if you want the MMR server
4. Python 3 optional (offline balance tools)

### One-click install

**Windows:** run `install.bat`  
**Linux/macOS:**

```bash
chmod +x install.sh
./install.sh "/path/to/dota 2 beta"
```

Installer copies `game/` → `dota 2 beta/game/dota_addons/dota-lod-deathroll/`.

## Play (V1.0)

1. Optional: `./start-mmr-server.sh` → http://localhost:3000
2. Steam → Dota 2 → **Launch Dota 2 - Tools**
3. Select **`dota-lod-deathroll`** → **Play**
4. Draft flow:
   - **Ban** one hero (30s)
   - **Hero draft**: pick from your random 3×4 (reroll a category once)
   - **Ability draft**: choose 3 basics, then 1 ultimate from global random offers
   - **2nd ultimate**: pick from 6 options and **Confirm lock** (no rerolls)
   - **Strategy**: buy starting items using the normal shop; keep the same hero and inventory
   - **Player introduction** → spawn → fight with **3 basics + 2 ultimates**
   - On every death: stage basic/ultimate replacements, then **Confirm loadout**
   - At Ancient destruction: victory/defeat → MVP + runner-up → final scoreboard

### Draft rules

- Picks must belong to the current server-generated offer. Basic and ultimate slots cannot exchange types.
- Initial draft timeouts complete missing choices automatically.
- Death drafts permit multiple replacements, but keep exactly **3 basics and 2 ultimates**. Select an existing slot, choose its replacement, and repeat for other slots before confirming.
- Each death grants **three shared rerolls** for both offer pools: **3 → 2 → 1 → 0**. A reroll clears staged changes. At zero only rerolling is locked; selection and confirmation remain available.
- Confirming without changes keeps the current kit. A death-draft timeout also keeps the original kit, discarding unconfirmed changes.
- **Keep original in selected slot** undoes a staged replacement without spending a reroll.
- Upgrade-granted abilities are limited to an explicit supported allowlist and require the corresponding Scepter/Shard and compatible dependencies. This is not blanket support for every Dota upgrade ability.
- MVP score is **kills + assists − deaths**, with ties resolved by hero damage and then player ID. “Next MVP” is the runner-up across both teams.
- Dota's standard post-game menu handles returning/leaving after the custom results panel is closed.

### Preparation and upgrade eligibility

Strategy and introduction are **custom HUD phases in engine PRE_GAME**, not the native hero-selection screens. The server pauses the engine clock during UI readiness and drafting; their countdowns use real time. Once final heroes and kits exist, shopping is unpaused for up to **30 seconds**, followed by a **5-second** introduction. Combat and movement remain blocked until gameplay. Starting items are purchased manually, not granted automatically.

UI readiness has a **15-second** grace period. Disconnected players do not block readiness/strategy indefinitely; draft timeouts complete their kits and the UI requests a fresh snapshot on load. Hero preparation retries for up to **30 seconds**; an unrecoverable failure ends setup without awarding either team victory.

Death drafts use a **25-second** game-time deadline, respect gameplay pauses, and do not shorten the normal respawn deadline. Buyback is blocked while a death draft is pending.

The current conservative upgrade allowlist consumes basic slots:

| Ability | Required upgrade | Required drafted parent |
|---------|------------------|-------------------------|
| `zuus_cloud` | Scepter | `zuus_lightning_bolt` |
| `juggernaut_swift_slash` | Scepter | `juggernaut_omni_slash` |
| `slark_depth_shroud` | Shard | `slark_shadow_dance` |

Ownership and retained dependencies are checked again at confirmation. These engine abilities are patch-sensitive: verify them in the installed Dota build before expanding the allowlist. Unsupported ability creation rejects the change without discarding the old kit.

### In-game acceptance checks

These require **Dota 2 Workshop Tools**; source syntax checks alone cannot verify engine behavior.

- Start a lobby with multiple players and a bot; verify banning and four non-banned offers in each category.
- Verify each category permits exactly one reroll, and initial picks finish with three basics and two ultimates.
- Buy items in strategy; verify introduction and gameplay preserve the hero, items, and kit.
- Disconnect/reconnect during drafting and preparation; verify UI recovery and that missing players do not permanently block the match.
- Die repeatedly; stage multiple basic/ultimate changes, exhaust all three rerolls, and confirm while rerolls are locked.
- Let a death draft expire; verify the original kit is retained. Check buyback cannot bypass an active draft.
- Check upgrade-granted abilities with and without the required item and dependencies.
- Destroy an Ancient while a death draft is pending; verify one results snapshot, cancelled drafts, and stable MVP/scoreboard values.

### Console check

```
[AI-LOD] InitGameMode (V1.0 LOD draft, ENABLE_LOD_DRAFT=true)
[HeroManager] Loaded N heroes (Str=… Agi=… Int=…)
[AbilityManager] Loaded … defs, … blacklisted, pools R=… U=…
[GameState] WAITING -> BAN
[GameState] BAN -> HERO_DRAFT
…
[GameState] SPAWN -> PLAYING
```

## Offline tools (Phases 13–14)

```bash
python3 tools/balance_engine.py --budget 28
python3 tools/ai_analyzer.py --samples 800
```

See `tools/README.md`.

## MMR server (optional)

```bash
cd mmr-server && npm install && npm start
```

See `mmr-server/` and `scripts/vscripts/mmr/client.lua` (`MMR_SERVER_URL`).
