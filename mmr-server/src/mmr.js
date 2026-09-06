// mmr.js
// ELO-style MMR calculation for LOD Deathroll matches.

const K_FACTOR = 32;
const START_MMR = 1000;

/**
 * Expected score of player A against the average rating of the opposing team.
 */
function expectedScore(playerMMR, opponentAvgMMR) {
  return 1 / (1 + Math.pow(10, (opponentAvgMMR - playerMMR) / 400));
}

/**
 * Compute the new MMR for a player given the result.
 *
 * @param {number} playerMMR      Player's current MMR
 * @param {number} opponentAvgMMR Average MMR of the opposing team
 * @param {boolean} won           Whether the player's team won
 * @returns {number} New MMR (never below 0)
 */
function calculateNewMMR(playerMMR, opponentAvgMMR, won) {
  const expected = expectedScore(playerMMR, opponentAvgMMR);
  const actual = won ? 1 : 0;
  return Math.max(0, Math.round(playerMMR + K_FACTOR * (actual - expected)));
}

module.exports = { calculateNewMMR, expectedScore, K_FACTOR, START_MMR };
