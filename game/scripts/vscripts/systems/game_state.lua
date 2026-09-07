-- systems/game_state.lua
-- Central match state machine. Server is the sole authority.

GameState = GameState or {}

GameState.WAITING = 0
GameState.BAN = 1
GameState.HERO_DRAFT = 2
GameState.ABILITY_DRAFT = 3
GameState.ULTIMATE_DRAFT = 4
GameState.SPAWN = 5
GameState.PLAYING = 6
GameState.RESPAWN_DRAFT = 7
GameState.GAME_OVER = 8
GameState.STRATEGY = 9
GameState.INTRODUCTION = 10
GameState.LOBBY = GameState.WAITING

local NAME = {
	[0] = "WAITING",
	[1] = "BAN",
	[2] = "HERO_DRAFT",
	[3] = "ABILITY_DRAFT",
	[4] = "ULTIMATE_DRAFT",
	[5] = "SPAWN",
	[6] = "PLAYING",
	[7] = "RESPAWN_DRAFT",
	[8] = "GAME_OVER",
	[9] = "STRATEGY",
	[10] = "INTRODUCTION",
}

-- Legal transitions for the full LOD design. V0.1 only uses a subset.
local ALLOWED = {
	[GameState.WAITING] = {
		[GameState.BAN] = true,
		[GameState.STRATEGY] = true,
		[GameState.GAME_OVER] = true,
	},
	[GameState.BAN] = {
		[GameState.HERO_DRAFT] = true,
		[GameState.GAME_OVER] = true,
	},
	[GameState.HERO_DRAFT] = {
		[GameState.ABILITY_DRAFT] = true,
		[GameState.GAME_OVER] = true,
	},
	[GameState.ABILITY_DRAFT] = {
		[GameState.ULTIMATE_DRAFT] = true,
		[GameState.GAME_OVER] = true,
	},
	[GameState.ULTIMATE_DRAFT] = {
		[GameState.STRATEGY] = true,
		[GameState.GAME_OVER] = true,
	},
	[GameState.STRATEGY] = {
		[GameState.INTRODUCTION] = true,
		[GameState.GAME_OVER] = true,
	},
	[GameState.INTRODUCTION] = {
		[GameState.SPAWN] = true,
		[GameState.GAME_OVER] = true,
	},
	[GameState.SPAWN] = {
		[GameState.PLAYING] = true,
		[GameState.GAME_OVER] = true,
	},
	[GameState.PLAYING] = {
		[GameState.RESPAWN_DRAFT] = true,
		[GameState.GAME_OVER] = true,
	},
	[GameState.RESPAWN_DRAFT] = {
		[GameState.PLAYING] = true,
		[GameState.GAME_OVER] = true,
	},
	[GameState.GAME_OVER] = {},
}

function GameState:Init(owner)
	self.owner = owner
	self.current = GameState.WAITING
	self.listeners = {}
	self.history = {}
	self.locked = false
	print("[GameState] Initialized at WAITING")
end

function GameState:Get()
	return self.current
end

function GameState:Name(state)
	return NAME[state or self.current] or "UNKNOWN"
end

function GameState:Is(state)
	return self.current == state
end

function GameState:In(...)
	local cur = self.current
	for i = 1, select("#", ...) do
		if cur == select(i, ...) then
			return true
		end
	end
	return false
end

function GameState:OnEnter(state, callback)
	self.listeners[state] = self.listeners[state] or {}
	table.insert(self.listeners[state], callback)
end

function GameState:CanTransition(toState)
	if toState == GameState.GAME_OVER and self.current ~= GameState.GAME_OVER then
		return true
	end
	if self.locked then
		return false
	end
	local from = ALLOWED[self.current]
	return from ~= nil and from[toState] == true
end

function GameState:Transition(toState, payload)
	if not self:CanTransition(toState) then
		print(string.format(
			"[GameState] BLOCKED transition %s -> %s",
			self:Name(self.current),
			self:Name(toState)
		))
		return false
	end

	local fromState = self.current
	table.insert(self.history, {
		from = fromState,
		to = toState,
		time = GameRules:GetGameTime(),
	})
	self.current = toState

	print(string.format(
		"[GameState] %s -> %s",
		self:Name(fromState),
		self:Name(toState)
	))

	local statePayload = {
		state = toState,
		name = self:Name(toState),
		from = fromState,
		from_name = self:Name(fromState),
	}
	CustomNetTables:SetTableValue("ai_lod_match", "state", statePayload)
	CustomGameEventManager:Send_ServerToAllClients("ai_lod_state", statePayload)

	local cbs = self.listeners[toState]
	if cbs then
		for _, cb in ipairs(cbs) do
			local ok, err = pcall(cb, payload, fromState, toState)
			if not ok then
				print("[GameState] listener error: " .. tostring(err))
			end
		end
	end

	return true
end

function GameState:Lock()
	self.locked = true
end

function GameState:Unlock()
	self.locked = false
end
