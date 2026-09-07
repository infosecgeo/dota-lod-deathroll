-- Minimal Timers library for LOD Deathroll (Think-based).
-- API: Timers:CreateTimer(fn) -> id; Timers:RemoveTimer(id)

if Timers == nil then
	Timers = {}
end

Timers.timers = Timers.timers or {}
Timers.nextId = Timers.nextId or 1
Timers.started = Timers.started or false

local THINK_NAME = "LODDeathrollTimers"
local TICK = 0.03

function Timers:Start()
	if self.started then return end
	self.started = true
	local mode = GameRules:GetGameModeEntity()
	if not mode then
		print("[Timers] WARNING: GameModeEntity missing; retrying")
		self.started = false
		return
	end
	mode:SetContextThink(THINK_NAME, function()
		return Timers:Think()
	end, TICK)
end

function Timers:Think()
	local now = GameRules:GetGameTime()
	for id, t in pairs(self.timers) do
		if t.endTime <= now then
			local status, nextDelay = pcall(t.callback)
			if not status then
				print("[Timers] Error in timer " .. tostring(id) .. ": " .. tostring(nextDelay))
				self.timers[id] = nil
			elseif type(nextDelay) == "number" and nextDelay > 0 then
				t.endTime = now + nextDelay
			else
				self.timers[id] = nil
			end
		end
	end
	return TICK
end

-- CreateTimer(callback) where callback returns seconds until next fire, or nil/false to stop.
function Timers:CreateTimer(callback)
	self:Start()
	local id = self.nextId
	self.nextId = self.nextId + 1
	local now = GameRules:GetGameTime()
	if now < 0 then now = 0 end
	self.timers[id] = {
		endTime = now,
		callback = callback,
	}
	return id
end

function Timers:RemoveTimer(id)
	if id then
		self.timers[id] = nil
	end
end
