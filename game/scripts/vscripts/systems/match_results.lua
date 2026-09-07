MatchResults = MatchResults or {}

function MatchResults:Snapshot(winner)
	local players = {}
	PlayerState:ForEachParticipant(function(playerID, record)
		local kills = PlayerResource:GetKills(playerID)
		local deaths = PlayerResource:GetDeaths(playerID)
		local assists = PlayerResource:GetAssists(playerID)
		table.insert(players, {
			player_id = playerID,
			team = PlayerResource:GetTeam(playerID),
			hero = record.hero or "",
			kills = kills,
			deaths = deaths,
			assists = assists,
			hero_damage = PlayerResource:GetRawPlayerDamage(playerID),
			score = kills + assists - deaths,
		})
	end)
	table.sort(players, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		if a.hero_damage ~= b.hero_damage then return a.hero_damage > b.hero_damage end
		return a.player_id < b.player_id
	end)
	for rank, player in ipairs(players) do
		player.rank = rank
	end
	return {
		winner = winner,
		mvp = players[1] and players[1].player_id or -1,
		runner_up = players[2] and players[2].player_id or -1,
		players = players,
	}
end
