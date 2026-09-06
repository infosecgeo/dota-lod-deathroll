# dota-lod-deathroll
A Dota 2 Arcade custom game: LOD-style ability draft (ban phase, category hero select with rerolls, 4+1 draft, extra ultimate incl. shard skills, death-reroll skills) + local MMR backend (Node.js + SQLite3) with ranking dashboard.

## Project layout

- **`game/`** — the Dota 2 custom game addon
  - `addoninfo.txt` — addon metadata
  - `scripts/npc/` — KeyValues files (hero categories, draft ability pools)
  - `scripts/vscripts/` — server-side Lua game logic
  - `panorama/` — draft UI (XML/CSS/JS)
  - `resource/` — localization
- **`mmr-server/`** — local MMR backend (Node.js + Express + SQLite3) with a ranking dashboard

## Game flow

1. **Ban phase** — every player bans one ability.
2. **Hero select** — players are offered one hero per category (Strength / Agility / Intelligence / Universal) and can reroll up to 2 times.
3. **Ability draft (4+1)** — each player drafts 4 regular abilities and 1 ultimate.
4. **Battle** — everyone also receives a random extra ultimate (including shard skills). On death, one of your skills is randomly rerolled from the death-reroll pool (30 s cooldown).

## Installation — step by step (plug and play)

### Prerequisites
1. **Dota 2** installed via Steam.
2. **Dota 2 Workshop Tools** — in Steam: `Library → Dota 2 → DLC → check "Dota 2 Workshop Tools"` → install.
3. **Node.js LTS (22 or newer)** from <https://nodejs.org> (only needed for the MMR server/leaderboard). The bundled SQLite library ships prebuilt binaries for current Node.js LTS releases — no C++/Visual Studio build tools are required. If `npm install` tries to compile with `node-gyp`, your Node.js version is too new or too old; install the current LTS instead.

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
4. Ban → pick a hero from each category (2 rerolls) → draft 4 abilities + 1 ultimate → fight!

> **Note:** The hero pool includes **all Dota 2 heroes** (Strength / Agility / Intelligence / Universal). The full draft ability pool lives in `game/scripts/npc/npc_abilities_custom.txt` — edit it to taste.

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
