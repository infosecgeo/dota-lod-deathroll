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

## Setup — Dota 2 addon

1. Install **Dota 2 Workshop Tools**.
2. Symlink or copy `game/` into `dota 2 beta/game/dota_addons/dota-lod-deathroll/` and `content/` into `dota 2 beta/content/dota_addons/dota-lod-deathroll/`.
3. Launch the Workshop Tools and open the addon.

## Setup — MMR server

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
