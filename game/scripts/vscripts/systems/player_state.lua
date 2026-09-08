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
		draftState = "LOBBY",
		deathCount = 0,
		ultimateConfirmed = false,
		draftLocked = false,
		draftId = 0,
		respawnPending = false,
		clientReady = false,
		lobbyReady = false,
		buildConfirmed = false,
		strategyReady = false,
		prepared = false,
	}
end

function PlayerState:Init()
	self.players = {}
	self.roster = nil
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
	self:ForEachParticipant(function(playerID, record)
		if self:IsConnected(playerID) then
			fn(playerID, record)
		end
	end)
end

function PlayerState:IsParticipant(playerID)
	if type(playerID) ~= "number" or playerID % 1 ~= 0 or playerID < 0 or playerID >= DOTA_MAX_PLAYERS then
		return false
	end
	if self.roster then return self.roster[playerID] ~= nil end
	if not PlayerResource:IsValidPlayerID(playerID) then return false end
	local team = PlayerResource:GetTeam(playerID)
	return team == DOTA_TEAM_GOODGUYS or team == DOTA_TEAM_BADGUYS
end

function PlayerState:LockRoster()
	if self.roster then return end
	local roster = {}
	self:ForEachParticipant(function(playerID, record)
		record.team = PlayerResource:GetTeam(playerID)
		roster[playerID] = record.team
	end)
	self.roster = roster
end

function PlayerState:GetTeam(playerID)
	return self.roster and self.roster[playerID] or PlayerResource:GetTeam(playerID)
end

function PlayerState:IsConnected(playerID)
	return self:IsParticipant(playerID)
		and PlayerResource:GetConnectionState(playerID) == DOTA_CONNECTION_STATE_CONNECTED
end

function PlayerState:IsBot(playerID)
	return self:IsParticipant(playerID)
		and PlayerResource:IsFakeClient(playerID)
end

function PlayerState:ForEachParticipant(fn)
	for playerID = 0, DOTA_MAX_PLAYERS - 1 do
		if self:IsParticipant(playerID) then
			fn(playerID, self:Ensure(playerID))
		end
	end
end
