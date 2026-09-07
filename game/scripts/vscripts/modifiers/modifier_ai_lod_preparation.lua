modifier_ai_lod_preparation = class({})

function modifier_ai_lod_preparation:IsHidden() return true end
function modifier_ai_lod_preparation:IsPurgable() return false end
function modifier_ai_lod_preparation:RemoveOnDeath() return false end

function modifier_ai_lod_preparation:CheckState()
	return {
		[MODIFIER_STATE_ROOTED] = true,
		[MODIFIER_STATE_DISARMED] = true,
		[MODIFIER_STATE_SILENCED] = true,
		[MODIFIER_STATE_MUTED] = true,
		[MODIFIER_STATE_INVULNERABLE] = true,
	}
end
