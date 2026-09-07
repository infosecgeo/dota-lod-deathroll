// db.js
// SQLite database layer for the LOD Deathroll MMR backend.
// Uses Node.js built-in node:sqlite (no native compile / Visual Studio required).

const { DatabaseSync } = require("node:sqlite");
const path = require("path");

const DB_PATH = path.join(__dirname, "..", "mmr.db");
const db = new DatabaseSync(DB_PATH);

db.exec("PRAGMA journal_mode = WAL");

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

/**
 * better-sqlite3-compatible transaction helper for node:sqlite.
 * Usage: transaction(() => { ... })()
 */
function transaction(fn) {
  return (...args) => {
    db.exec("BEGIN IMMEDIATE");
    try {
      const result = fn(...args);
      db.exec("COMMIT");
      return result;
    } catch (err) {
      try {
        db.exec("ROLLBACK");
      } catch (_) {
        /* ignore rollback errors */
      }
      throw err;
    }
  };
}

// Attach so callers can use db.db.transaction(...) like better-sqlite3.
db.transaction = transaction;

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
