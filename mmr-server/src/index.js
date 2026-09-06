// index.js
// Express REST API for the LOD Deathroll local MMR backend.

const express = require("express");
const path = require("path");
const db = require("./db");
const { calculateNewMMR } = require("./mmr");

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());
app.use(express.static(path.join(__dirname, "..", "public")));

// ---------------------------------------------------------------------------
// POST /players
// Register or update a player. Body: { steam_id, name }
// ---------------------------------------------------------------------------
app.post("/players", (req, res) => {
  const { steam_id, name } = req.body;
  if (!steam_id || !name) {
    return res.status(400).json({ error: "steam_id and name are required" });
  }
  db.insertPlayer.run(String(steam_id), String(name));
  const player = db.getPlayerBySteamId.get(String(steam_id));
  res.json(player);
});

// ---------------------------------------------------------------------------
// POST /matches
// Report a finished match. Body:
// { winner_team, players: [{ steam_id, team, hero, kills, deaths }] }
// Updates MMR for every participant.
// ---------------------------------------------------------------------------
app.post("/matches", (req, res) => {
  const { winner_team, players } = req.body;
  if (winner_team === undefined || !Array.isArray(players) || players.length === 0) {
    return res.status(400).json({ error: "winner_team and a non-empty players array are required" });
  }

  const winners = players.filter((p) => p.team === winner_team);
  const losers = players.filter((p) => p.team !== winner_team);
  const avg = (arr) =>
    arr.length
      ? arr.reduce((sum, p) => {
          const rec = db.getPlayerBySteamId.get(String(p.steam_id));
          return sum + (rec ? rec.mmr : 1000);
        }, 0) / arr.length
      : 1000;
  const winnersAvg = avg(winners);
  const losersAvg = avg(losers);

  const result = db.db.transaction(() => {
    const info = db.insertMatch.run(winner_team);
    const matchId = info.lastInsertRowid;

    const results = players.map((p) => {
      const steamId = String(p.steam_id);
      let rec = db.getPlayerBySteamId.get(steamId);
      if (!rec) {
        db.insertPlayer.run(steamId, steamId);
        rec = db.getPlayerBySteamId.get(steamId);
      }

      const won = p.team === winner_team;
      const oppAvg = won ? losersAvg : winnersAvg;
      const newMMR = calculateNewMMR(rec.mmr, oppAvg, won);

      db.updateMMR.run(newMMR, won ? 1 : 0, won ? 0 : 1, rec.id);
      db.insertMatchPlayer.run(
        matchId,
        rec.id,
        p.team,
        p.hero || null,
        p.kills || 0,
        p.deaths || 0,
        rec.mmr,
        newMMR
      );

      return { steam_id: steamId, mmr_before: rec.mmr, mmr_after: newMMR, won };
    });

    return { match_id: matchId, results };
  })();

  res.json(result);
});

// ---------------------------------------------------------------------------
// GET /leaderboard?limit=N
// ---------------------------------------------------------------------------
app.get("/leaderboard", (req, res) => {
  const limit = Math.min(parseInt(req.query.limit, 10) || 100, 500);
  res.json(db.leaderboard.all(limit));
});

// ---------------------------------------------------------------------------
// GET /players/:steam_id
// Player profile + match history.
// ---------------------------------------------------------------------------
app.get("/players/:steam_id", (req, res) => {
  const player = db.getPlayerBySteamId.get(String(req.params.steam_id));
  if (!player) return res.status(404).json({ error: "player not found" });
  const history = db.playerHistory.all(player.id);
  res.json({ ...player, history });
});

app.listen(PORT, () => {
  console.log(`LOD Deathroll MMR server listening on http://localhost:${PORT}`);
  console.log(`Dashboard: http://localhost:${PORT}/`);
});
