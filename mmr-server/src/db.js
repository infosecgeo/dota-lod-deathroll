// db.js
// SQLite3 database layer for the LOD Deathroll MMR backend.

const Database = require("better-sqlite3");
const path = require("path");

const DB_PATH = path.join(__dirname, "..", "mmr.db");
const db = new Database(DB_PATH);

db.pragma("journal_mode = WAL");

db.exec(`
  CREATE TABLE IF NOT EXISTS players (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    steam_id    TEXT    NOT NULL UNIQUE,
    name        TEXT    NOT NULL,
    mmr         INTEGER NOT NULL DEFAULT 1000,
    wins        INTEGER NOT NULL DEFAULT 0,
    losses      INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT    NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS matches (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    winner_team  INTEGER NOT NULL,
    played_at    TEXT    NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS match_players (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    match_id   INTEGER NOT NULL REFERENCES matches(id),
    player_id  INTEGER NOT NULL REFERENCES players(id),
    team       INTEGER NOT NULL,
    hero       TEXT,
    kills      INTEGER NOT NULL DEFAULT 0,
    deaths     INTEGER NOT NULL DEFAULT 0,
    mmr_before INTEGER NOT NULL,
    mmr_after  INTEGER NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_match_players_match ON match_players(match_id);
  CREATE INDEX IF NOT EXISTS idx_match_players_player ON match_players(player_id);
`);

const getPlayerBySteamId = db.prepare("SELECT * FROM players WHERE steam_id = ?");
const insertPlayer = db.prepare(
  "INSERT INTO players (steam_id, name) VALUES (?, ?) ON CONFLICT(steam_id) DO UPDATE SET name = excluded.name"
);
const updateMMR = db.prepare(
  "UPDATE players SET mmr = ?, wins = wins + ?, losses = losses + ?, updated_at = datetime('now') WHERE id = ?"
);
const insertMatch = db.prepare("INSERT INTO matches (winner_team) VALUES (?)");
const insertMatchPlayer = db.prepare(
  "INSERT INTO match_players (match_id, player_id, team, hero, kills, deaths, mmr_before, mmr_after) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
);
const leaderboard = db.prepare(
  "SELECT steam_id, name, mmr, wins, losses, (wins + losses) AS games FROM players ORDER BY mmr DESC LIMIT ?"
);
const playerHistory = db.prepare(`
  SELECT mp.mmr_before, mp.mmr_after, mp.team, mp.hero, mp.kills, mp.deaths, m.played_at, m.winner_team
  FROM match_players mp
  JOIN matches m ON m.id = mp.match_id
  WHERE mp.player_id = ?
  ORDER BY m.played_at DESC
  LIMIT 50
`);

module.exports = {
  db,
  getPlayerBySteamId,
  insertPlayer,
  updateMMR,
  insertMatch,
  insertMatchPlayer,
  leaderboard,
  playerHistory,
};
