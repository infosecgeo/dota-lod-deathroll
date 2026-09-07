-- systems/draft_manager.lua
-- Orchestrates hero / ability / ultimate draft phases (Phase 4+).
-- Stubbed for V0.1 — not entered by the state machine yet.

DraftManager = DraftManager or class({})

function DraftManager:constructor(heroManager, abilityManager)
	self.heroManager = heroManager
	self.abilityManager = abilityManager
	self.active = false
end

function DraftManager:StartHeroDraft(onComplete)
	print("[DraftManager] Hero draft not implemented in V0.1 — auto-complete")
	if onComplete then onComplete() end
end

function DraftManager:StartAbilityDraft(onComplete)
	print("[DraftManager] Ability draft not implemented in V0.1 — auto-complete")
	if onComplete then onComplete() end
end

function DraftManager:StartUltimateDraft(onComplete)
	print("[DraftManager] Ultimate draft not implemented in V0.1 — auto-complete")
	if onComplete then onComplete() end
end
