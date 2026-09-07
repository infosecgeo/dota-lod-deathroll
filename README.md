# dota-lod-deathroll
A Dota 2 Arcade custom game: LOD-style ability draft (ban phase, 3×4 category hero pool, 4+1 skill draft, extra ultimate, death-reroll skills) + local MMR backend (Node.js + built-in SQLite) with ranking dashboard.

## Project layout

- **`game/`** — the Dota 2 custom game addon
  - `addoninfo.txt` — addon metadata
  - `scripts/npc/` — KeyValues files (hero categories, draft ability pools)
  - `scripts/vscripts/` — server-side Lua game logic
  - `panorama/` — draft UI (XML/CSS/JS)
  - `resource/` — localization
- **`mmr-server/`** — local MMR backend (Node.js + Express + built-in SQLite) with a ranking dashboard

## Game flow (LOD, not normal picking)

Vanilla hero selection is **disabled**. The match uses a custom LOD draft UI instead:

1. **Ban phase** — every player bans one ability from the pool.
2. **Hero select** — fixed pool of **3 categories × 4 heroes** (12 total). Pick one hero.
3. **Ability draft (4+1)** — draft **4 regular abilities + 1 ultimate** from skills belonging to that hero pool.
4. **Battle** — your hero is spawned with drafted skills; everyone also gets a random extra ultimate. On death, one skill is randomly rerolled (30 s cooldown).

### Hero pool

| Strength | Agility | Intelligence |
|----------|---------|--------------|
| Axe | Juggernaut | Lina |
| Pudge | Phantom Assassin | Lion |
| Sven | Sniper | Crystal Maiden |
| Legion Commander | Anti-Mage | Zeus |

Edit `game/scripts/npc/hero_categories.txt` (Lua pools) and `game/scripts/npc/herolist.txt` (engine enable list) together. Ability pools for those heroes live in `game/scripts/npc/draft_abilities.txt` (real Dota ability names).

## Installation — step by step (plug and play)

### Prerequisites
1. **Dota 2** installed via Steam.
2. **Dota 2 Workshop Tools** — in Steam: `Library → Dota 2 → DLC → check "Dota 2 Workshop Tools"` → install.
3. **Node.js LTS (22.5 or newer)** from <https://nodejs.org> (only needed for the MMR server/leaderboard). The MMR server uses Node’s built-in SQLite (`node:sqlite`) — **no C++/Visual Studio build tools**. Prefer the current **LTS** installer from nodejs.org.

### Option A — one-click install (recommended)

**Windows:** double-click **`install.bat`** (or run it in a terminal). If it can't find Dota, it will ask you to paste the path to your `dota 2 beta` folder, e.g.
```
install.bat "C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta"
```

**Linux/macOS:**
```bash
chmod +x install.sh
./install.sh "/path/to/dota 2 beta"   # defaults to ~/.steam/steam/steamapps/common/dota 2 beta
```

The installer copies the addon into `dota 2 beta/game/dota_addons/dota-lod-deathroll/` and installs the MMR server dependencies.

### Option B — manual install
1. Copy the **`game/`** folder into `dota 2 beta/game/dota_addons/` and rename it to **`dota-lod-deathroll`** (so you end up with `dota 2 beta/game/dota_addons/dota-lod-deathroll/addoninfo.txt`).
2. Set up the MMR server:
   ```bash
   cd mmr-server
   npm install
   ```

### Play
1. **Start the MMR server** (optional but needed for MMR tracking):
   - Windows: double-click **`start-mmr-server.bat`**
   - Linux/macOS: **`./start-mmr-server.sh`**
   - Dashboard opens at <http://localhost:3000>
2. **Launch Dota 2 with Workshop Tools**: right-click Dota 2 in Steam → `Play… → Launch Dota 2 - Tools` (or add `-tools` to launch options).
3. In the Workshop Tools launcher, select **`dota-lod-deathroll`** and press **Play** (or run `dota_launch_custom_game dota-lod-deathroll dota` from the tools console).
4. You should **not** see normal hero picking. Instead: Ban → pick a hero from the 3×4 pool → draft 4 abilities + 1 ultimate → fight!

> **Still seeing normal picking / empty UI?** Re-run `install.bat` / `install.sh` so files are copied into `dota_addons/dota-lod-deathroll`, then fully restart Workshop Tools. Confirm `herolist.txt` root key is `"herolist"` with `"1"` entries, and that `draft_abilities.txt` is present next to it.

## MMR server

```bash
cd mmr-server
npm install
npm start
```

The API listens on `http://localhost:3000`:

| Endpoint | Description |
|----------|-------------|
| `POST /players` | Register/update a player (`{ steam_id, name }`) |
| `POST /matches` | Report a match; updates MMR (ELO, K=32) |
| `GET /leaderboard` | Top players by MMR |
| `GET /players/:steam_id` | Player profile + match history |
| `GET /` | Ranking dashboard |

The game reports match results via `scripts/vscripts/mmr/client.lua` (configure `MMR_SERVER_URL` there).
