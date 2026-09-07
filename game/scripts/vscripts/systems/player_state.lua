-- systems/player_state.lua
-- Per-player source of truth. Server-owned; clients never mutate this table.

PlayerState = PlayerState or {}

local function NewPlayerRecord(playerID)
	return {
		playerID = playerID,
		hero = nil,
		abilities = {
			basic = {},
			ultimate = {},
		},
		bannedHeroes = {},
		heroPools = {},
		rerolls = {
			heroCategory1 = 1,
			heroCategory2 = 1,
			heroCategory3 = 1,
			respawn = 3,
		},
		draftState = "WAITING",
		deathCount = 0,
		ultimateConfirmed = false,
		draftLocked = false,
		draftId = 0,
		respawnPending = false,
	}
end

function PlayerState:Init()
	self.players = {}
	print("[PlayerState] Initialized")
end

function PlayerState:Ensure(playerID)
	if not playerID or playerID < 0 then
		return nil
	end
	if not self.players[playerID] then
		self.players[playerID] = NewPlayerRecord(playerID)
	end
	return self.players[playerID]
end

function PlayerState:Get(playerID)
	return self:Ensure(playerID)
end

function PlayerState:SetHero(playerID, heroName)
	local p = self:Ensure(playerID)
	if not p then return end
	p.hero = heroName
end

function PlayerState:GetHero(playerID)
	local p = self.players[playerID]
	return p and p.hero or nil
end

function PlayerState:IncDeath(playerID)
	local p = self:Ensure(playerID)
	if not p then return 0 end
	p.deathCount = (p.deathCount or 0) + 1
	return p.deathCount
end

function PlayerState:ResetRespawnRerolls(playerID)
	local p = self:Ensure(playerID)
	if not p then return end
	p.rerolls.respawn = 3
end

function PlayerState:ForEachConnected(fn)
	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if PlayerResource:IsValidPlayerID(playerID)
			and PlayerResource:GetConnectionState(playerID) ~= DOTA_CONNECTION_STATE_ABANDONED then
			fn(playerID, self:Ensure(playerID))
		end
	end
end
