-- systems/reroll_manager.lua
-- Category + respawn rerolls (Phase 4 / 11). Stub for V0.1.

RerollManager = RerollManager or class({})

function RerollManager:constructor()
end

function RerollManager:CanReroll(playerID, bucket)
	local p = PlayerState and PlayerState:Get(playerID)
	if not p or not p.rerolls then return false end
	local left = p.rerolls[bucket]
	return type(left) == "number" and left > 0
end

function RerollManager:Consume(playerID, bucket)
	local p = PlayerState and PlayerState:Get(playerID)
	if not p or not p.rerolls then return false end
	local left = p.rerolls[bucket]
	if type(left) ~= "number" or left <= 0 then
		return false
	end
	p.rerolls[bucket] = left - 1
	return true
end
