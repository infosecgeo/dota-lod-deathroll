# AI-LOD (`dota-lod-deathroll`)

Dota 2 Arcade custom game: modular LOD-style ability draft with death-draft, built on a **server-authoritative state machine**.

**Current milestone: V1.0 — full pool, polished LOD draft pipeline**

Flow:

```
WAITING → BAN (50s) → HERO_DRAFT (random 3×4 + rerolls) → ABILITY_DRAFT (4+1)
        → ULTIMATE_DRAFT (6 choices, confirm) → SPAWN (apply kit) → PLAYING
        → per-player DEATH DRAFT (3 rerolls, slot replace)
```

## Modules

```
AI-LOD
├── Game Flow      (WAITING → BAN → HERO_DRAFT → ABILITY_DRAFT → ULTIMATE_DRAFT → SPAWN → PLAYING → death draft)
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
| `ban_manager.lua` | 50s hero ban (Phase 3) |
| `draft_manager.lua` | Hero / ability / 2nd-ult draft |
| `reroll_manager.lua` | Category + death reroll budgets |
| `respawn_manager.lua` | Per-player death draft (3 rerolls) |
| `balance_manager.lua` | Power budget (reads `balance.kv`) |

Feature flag in `gamemode.lua`:

```lua
local ENABLE_LOD_DRAFT = true  -- V1.0 full LOD pipeline
```

## Roadmap

| Phase | Goal | Status |
|-------|------|--------|
| V0.1 / Phase 1–2 | Playable custom game + state machine | **done** |
| Phase 3 | 50s hero ban (server-validated) | **done** |
| Phase 4 | 3×4 hero pools + 1 reroll/category | **done** |
| Phase 5 | `abilities.kv` database | **done** |
| Phase 6–8 | 4 basic + 1 ult + spawn with kit | **done** |
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
   - **Ban** one hero (50s)
   - **Hero draft**: pick from your random 3×4 (reroll a category once)
   - **Ability draft**: 4 basics + 1 ultimate from random offers
   - **2nd ultimate**: pick from 6 options and **Confirm lock**
   - **Spawn** with kit applied → fight
   - On death: **death draft** replace one slot (3 rerolls)

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
