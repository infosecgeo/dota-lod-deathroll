# AI-LOD (`dota-lod-deathroll`)

Dota 2 Arcade custom game: modular LOD-style ability draft with death-draft, built on a **server-authoritative state machine**.

**Current milestone: V0.1 — empty playable foundation**

You can launch the addon locally, pick a hero from the enabled pool, move, attack, use abilities, die, and respawn. LOD draft phases are scaffolded but **disabled** until the current phase is solid.

## Modules

```
AI-LOD
├── Game Flow      (WAITING → BAN → HERO_DRAFT → ABILITY_DRAFT → ULTIMATE_DRAFT → SPAWN → PLAYING → RESPAWN_DRAFT)
├── Hero System    (pool, bans, restrictions)
├── Ability System (basic/ult/shard, blacklist, compatibility)
├── Draft System   (randomization, categories, rerolls, confirmation)
├── Player State   (skills, hero, deaths, rerolls)
└── UI             (ban / hero / ability / ultimate / respawn)
```

## Project layout

```
game/                          # copied to dota_addons/dota-lod-deathroll/
├── addoninfo.txt
├── scripts/
│   ├── config/                # KV: heroes, abilities, blacklist, balance
│   ├── npc/                   # engine herolist + legacy draft pools
│   └── vscripts/
│       ├── addon_game_mode.lua
│       ├── gamemode.lua       # wires systems + feature flags
│       ├── systems/           # state machine + managers
│       ├── libraries/
│       ├── draft/             # legacy draft scripts (not loaded in V0.1)
│       └── mmr/
├── panorama/                  # foundation HUD + draft layouts
└── resource/
mmr-server/                    # optional local MMR API + dashboard
tools/                         # future Python balance / sim tools
```

### Systems (`scripts/vscripts/systems/`)

| File | Role |
|------|------|
| `game_state.lua` | Central state machine (server authority) |
| `player_state.lua` | Per-player source of truth |
| `hero_manager.lua` | Hero pool / ban / spawn helpers |
| `ability_manager.lua` | Ability DB + blacklist hooks |
| `ban_manager.lua` | 50s hero ban (Phase 3) |
| `draft_manager.lua` | Hero / ability / ult draft orchestration |
| `reroll_manager.lua` | Category + death reroll budgets |
| `respawn_manager.lua` | Death → (future) respawn draft |
| `balance_manager.lua` | Power budget (reads `balance.kv`) |

Feature flag in `gamemode.lua`:

```lua
local ENABLE_LOD_DRAFT = false  -- V0.1 foundation; set true when Phase 3+ is ready
```

## Development stack

| Layer | Tech |
|-------|------|
| Game | Dota 2 Workshop Tools |
| Gameplay | Lua / VScript |
| UI | Panorama |
| Config | KeyValues |
| Balance tools | Python (offline; never mid-match) |
| VCS | Git |
| Optional MMR | Node.js ≥ 22.5 (`node:sqlite`) |

## Roadmap (do not skip ahead)

| Phase | Goal | Status |
|-------|------|--------|
| **V0.1 / Phase 1–2** | Playable custom game + state machine | **in progress** |
| Phase 3 | 50s hero ban (server-validated) | scaffolded |
| Phase 4 | 3×4 hero pools + 1 reroll/category | scaffolded |
| Phase 5 | `abilities.kv` database | scaffolded |
| Phase 6–8 | 4 basic + 1 ult + spawn with kit | planned |
| Phase 9 | 2nd ultimate (6 choices, confirm lock) | planned |
| Phase 10–12 | Death draft, 3 rerolls, slot replace | planned |
| Phase 13–14 | Python balance engine / AI analyzer | planned |
| V1.0 | Full pool, polished Arcade build | planned |

**Rule:** do not start the next major system until the current one works in Workshop Tools.

## Installation

### Prerequisites
1. Dota 2 (Steam)
2. **Dota 2 Workshop Tools** DLC
3. Node.js **22.5+** only if you want the MMR server

### One-click install

**Windows:** run `install.bat` (or pass your `dota 2 beta` path).

**Linux/macOS:**
```bash
chmod +x install.sh
./install.sh "/path/to/dota 2 beta"
```

Installer copies `game/` → `dota 2 beta/game/dota_addons/dota-lod-deathroll/`.

### Manual install
Copy `game/` to `dota_addons/dota-lod-deathroll/` so `addoninfo.txt` sits at that path.

## Play (V0.1)

1. Optional: `./start-mmr-server.sh` or `start-mmr-server.bat` → http://localhost:3000  
2. Steam → Dota 2 → **Launch Dota 2 - Tools** (or `-tools`)  
3. Select **`dota-lod-deathroll`** → **Play**  
   Console alternative:
   ```
   dota_launch_custom_game dota-lod-deathroll dota
   ```
4. Create / start the lobby  
5. **Pick a hero** from the enabled list (12 MVP heroes)  
6. Confirm you can **move, attack, cast, die, and respawn**

You should **not** see the LOD ban/draft overlay in V0.1. A small “AI-LOD · …” badge may appear briefly, then hide when `PLAYING`.

### Console check
In the tools console / server log look for:
```
[AI-LOD] InitGameMode (V0.1 foundation, ENABLE_LOD_DRAFT=false)
[GameState] WAITING -> SPAWN
[GameState] SPAWN -> PLAYING
```

## Enabling draft later

When Phase 3 is ready:

1. Implement real logic in `ban_manager` / `draft_manager`  
2. Set `ENABLE_LOD_DRAFT = true` in `gamemode.lua`  
3. Re-install addon and test **only** ban → hero draft before touching abilities  

## Architecture rules

- **Server owns state.** Clients send intent (“ban Axe”); server validates.  
- **No client-side RNG** for pools, bans, or rerolls.  
- **No live AI in-match.** Python writes `scripts/config/*.kv`; Lua only reads.  
- **One state machine** — no ad-hoc timers jumping phases without `GameState:Transition`.  
- **Transaction-style picks** — validate → commit → lock.

## MMR server (optional)

```bash
cd mmr-server && npm install && npm start
```

See `mmr-server/` and `scripts/vscripts/mmr/client.lua` (`MMR_SERVER_URL`).

## Hero pool (MVP)

Enabled in `scripts/npc/herolist.txt` and categorized in `scripts/config/heroes.kv` / `scripts/npc/hero_categories.txt`:

| Pool C (Tank) | Pool A (Carry) | Pool B (Utility) |
|---------------|----------------|------------------|
| Axe | Juggernaut | Lina |
| Pudge | Phantom Assassin | Lion |
| Sven | Sniper | Crystal Maiden |
| Legion Commander | Anti-Mage | Zeus |

## Next step for you

1. Re-run `install.bat` / `install.sh`  
2. Launch Tools → play `dota-lod-deathroll`  
3. Report: hero pick works? move/attack/cast/die/respawn OK? any console errors?  

Once V0.1 is confirmed, we implement **Phase 3 — 50-second hero ban** only.
