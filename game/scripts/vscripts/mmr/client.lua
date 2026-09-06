-- mmr/client.lua
-- Thin HTTP client that reports match results to the local MMR backend
-- (Node.js + SQLite3 server in mmr-server/).

MMRClient = MMRClient or class({})

local MMR_SERVER_URL = "http://localhost:3000"

function MMRClient:constructor()
	self.url = MMR_SERVER_URL
end

function MMRClient:RegisterPlayer(playerID, name)
	self:Post("/players", {
		steam_id = tostring(PlayerResource:GetSteamID(playerID)),
		name = name,
	})
end

function MMRClient:ReportMatch(winnerTeam, players)
	-- players: array of { player_id, steam_id, team, kills, deaths, hero }
	self:Post("/matches", {
		winner_team = winnerTeam,
		players = players,
	})
end

function MMRClient:Post(path, body)
	local request = CreateHTTPRequestScriptVM("POST", self.url .. path)
	request:SetHTTPRequestHeaderValue("Content-Type", "application/json")
	request:SetHTTPRequestRawPostBody("application/json", json.encode(body))
	request:Send(function(response)
		if response.StatusCode ~= 200 then
			print(string.format("[MMRClient] POST %s failed: %d", path, response.StatusCode))
		end
	end)
end
