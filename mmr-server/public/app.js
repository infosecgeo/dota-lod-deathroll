// app.js — fetches the leaderboard and renders it.
async function loadLeaderboard() {
  const tbody = document.getElementById("leaderboard-body");
  try {
    const res = await fetch("/leaderboard?limit=100");
    const players = await res.json();
    if (!players.length) {
      tbody.innerHTML = '<tr><td colspan="6">No players yet.</td></tr>';
      return;
    }
    tbody.innerHTML = players
      .map(
        (p, i) => `
      <tr>
        <td>${i + 1}</td>
        <td>${escapeHtml(p.name)}</td>
        <td class="mmr">${p.mmr}</td>
        <td>${p.wins}</td>
        <td>${p.losses}</td>
        <td>${p.games}</td>
      </tr>`
      )
      .join("");
  } catch (err) {
    tbody.innerHTML = '<tr><td colspan="6">Failed to load leaderboard.</td></tr>';
    console.error(err);
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[c]);
}

loadLeaderboard();
setInterval(loadLeaderboard, 30000);
