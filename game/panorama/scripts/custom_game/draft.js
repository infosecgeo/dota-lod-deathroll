// draft.js — full LOD draft UI (ban / hero / ability / ult / death)
"use strict";

var banPhasePanel = $("#BanPhase");
var heroSelectPanel = $("#HeroSelect");
var abilityDraftPanel = $("#AbilityDraft");
var ultDraftPanel = $("#UltDraft");
var deathDraftPanel = $("#DeathDraft");
var deathrollNotice = $("#DeathrollNotice");

function ShowPanel(panel) {
	[banPhasePanel, heroSelectPanel, abilityDraftPanel, ultDraftPanel, deathDraftPanel].forEach(function (p) {
		if (p) p.SetHasClass("Visible", p === panel);
	});
}

function HideAllDraftPanels() {
	[banPhasePanel, heroSelectPanel, abilityDraftPanel, ultDraftPanel, deathDraftPanel].forEach(function (p) {
		if (p) p.SetHasClass("Visible", false);
	});
}
HideAllDraftPanels();

function PrettyName(id) {
	if (!id) return "";
	return id
		.replace(/^npc_dota_hero_/, "")
		.replace(/_/g, " ");
}

function SplitList(s) {
	if (!s) return [];
	return String(s).split(",").filter(function (x) { return !!x; });
}

// ---------------------------------------------------------------------------
// State-driven hide when playing
// ---------------------------------------------------------------------------
GameEvents.Subscribe("ai_lod_state", function (event) {
	if (!event || !event.name) return;
	if (event.name === "PLAYING" || event.name === "SPAWN" || event.name === "GAME_OVER") {
		if (event.name !== "PLAYING") HideAllDraftPanels();
		// death draft may still show during PLAYING
		if (event.name !== "PLAYING") {
			if (deathDraftPanel) deathDraftPanel.SetHasClass("Visible", false);
		}
	}
});

GameEvents.Subscribe("ai_lod_playing", function () {
	ShowPanel(null);
	HideAllDraftPanels();
});

// ---------------------------------------------------------------------------
// Ban phase (heroes)
// ---------------------------------------------------------------------------
GameEvents.Subscribe("ai_lod_ban_start", function (event) {
	ShowPanel(banPhasePanel);
	var list = $("#BanAbilityList");
	list.RemoveAndDeleteChildren();
	SplitList(event.heroes).forEach(function (hero) {
		var btn = $.CreatePanel("Button", list, "ban_" + hero);
		var label = $.CreatePanel("Label", btn, "");
		label.text = PrettyName(hero);
		btn.SetPanelEvent("onactivate", (function (h) {
			return function () {
				GameEvents.SendCustomGameEventToServer("ai_lod_ban_hero", { hero: h });
				btn.SetHasClass("Banned", true);
			};
		})(hero));
	});
	if (event.time != null) {
		$("#BanTimer").text = String(event.time);
	}
});

GameEvents.Subscribe("ai_lod_hero_banned", function (event) {
	var btn = banPhasePanel.FindChildTraverse("ban_" + event.hero);
	if (btn) btn.SetHasClass("Banned", true);
});

GameEvents.Subscribe("ai_lod_ban_timer", function (event) {
	$("#BanTimer").text = String(event.time);
});

GameEvents.Subscribe("ai_lod_ban_end", function () {
	ShowPanel(null);
});

// ---------------------------------------------------------------------------
// Hero select — randomized 3x4 + reroll
// ---------------------------------------------------------------------------
function RenderHeroOffers(event) {
	ShowPanel(heroSelectPanel);
	var container = $("#HeroCategories");
	container.RemoveAndDeleteChildren();

	var categories = [
		{ key: "strength", name: "Strength", heroes: SplitList(event.strength), rerolls: event.reroll_str },
		{ key: "agility", name: "Agility", heroes: SplitList(event.agility), rerolls: event.reroll_agi },
		{ key: "intelligence", name: "Intelligence", heroes: SplitList(event.intelligence), rerolls: event.reroll_int },
	];

	categories.forEach(function (cat) {
		var panel = $.CreatePanel("Panel", container, "cat_" + cat.key);
		panel.AddClass("HeroCategory");
		var title = $.CreatePanel("Label", panel, "");
		title.AddClass("CategoryName");
		title.text = cat.name;

		cat.heroes.forEach(function (hero) {
			var btn = $.CreatePanel("Button", panel, "hero_" + hero);
			var label = $.CreatePanel("Label", btn, "");
			label.text = PrettyName(hero);
			btn.SetPanelEvent("onactivate", (function (h, button) {
				return function () {
					GameEvents.SendCustomGameEventToServer("ai_lod_pick_hero", { hero: h });
					button.SetHasClass("Selected", true);
				};
			})(hero, btn));
		});

		var rerollBtn = $.CreatePanel("Button", panel, "reroll_" + cat.key);
		rerollBtn.AddClass("RerollButton");
		var rLabel = $.CreatePanel("Label", rerollBtn, "");
		rLabel.text = "Reroll (" + String(cat.rerolls != null ? cat.rerolls : 0) + ")";
		if ((cat.rerolls || 0) <= 0) {
			rerollBtn.SetHasClass("Banned", true);
		}
		rerollBtn.SetPanelEvent("onactivate", (function (ck) {
			return function () {
				GameEvents.SendCustomGameEventToServer("ai_lod_reroll_hero", { category: ck });
			};
		})(cat.key));
	});

	if (event.time != null) {
		$("#HeroTimer").text = String(event.time);
	}
	var rerolls = $("#RerollsLeft");
	if (rerolls) rerolls.text = "Pick 1 hero from your randomized offers";
}

GameEvents.Subscribe("ai_lod_hero_draft_start", function (event) {
	ShowPanel(heroSelectPanel);
	if (event.time != null) $("#HeroTimer").text = String(event.time);
});

GameEvents.Subscribe("ai_lod_hero_offers", RenderHeroOffers);
// Legacy
GameEvents.Subscribe("lod_hero_offers", function (event) {
	RenderHeroOffers({
		strength: event.strength,
		agility: event.agility,
		intelligence: event.intelligence,
		reroll_str: 1, reroll_agi: 1, reroll_int: 1,
		time: event.time,
	});
});

GameEvents.Subscribe("ai_lod_hero_picked", function (event) {
	var notice = $("#RerollsLeft");
	if (notice) notice.text = "Picked: " + PrettyName(event.hero);
});

GameEvents.Subscribe("ai_lod_hero_timer", function (event) {
	$("#HeroTimer").text = String(event.time);
});
GameEvents.Subscribe("lod_hero_timer", function (event) {
	$("#HeroTimer").text = String(event.time);
});

GameEvents.Subscribe("ai_lod_hero_draft_end", function () {
	ShowPanel(null);
});
GameEvents.Subscribe("lod_hero_phase_end", function () {
	ShowPanel(null);
});

// ---------------------------------------------------------------------------
// Ability draft
// ---------------------------------------------------------------------------
function RenderAbilityOffers(event) {
	ShowPanel(abilityDraftPanel);

	var regular = $("#DraftRegularList");
	regular.RemoveAndDeleteChildren();
	SplitList(event.basic || event.regular).forEach(function (ability) {
		AddDraftButton(regular, ability, false);
	});

	var ultimate = $("#DraftUltimateList");
	ultimate.RemoveAndDeleteChildren();
	SplitList(event.ultimate).forEach(function (ability) {
		AddDraftButton(ultimate, ability, true);
	});

	$("#DraftPicked").RemoveAndDeleteChildren();
	var hint = $.CreatePanel("Label", $("#DraftPicked"), "draft_hint");
	var pb = SplitList(event.picked_basic);
	var pu = SplitList(event.picked_ultimate);
	hint.text = "Picked basics " + pb.length + "/4 · ults " + pu.length + "/1";
	if (event.time != null) {
		$("#DraftTimer").text = String(event.time);
	}
}

function AddDraftButton(parent, ability, isUlt) {
	var btn = $.CreatePanel("Button", parent, "draft_" + ability);
	var label = $.CreatePanel("Label", btn, "");
	label.text = PrettyName(ability);
	btn.SetPanelEvent("onactivate", (function (a) {
		return function () {
			GameEvents.SendCustomGameEventToServer("ai_lod_pick_ability", { ability: a });
		};
	})(ability));
}

GameEvents.Subscribe("ai_lod_ability_draft_start", function (event) {
	ShowPanel(abilityDraftPanel);
	if (event.time != null) $("#DraftTimer").text = String(event.time);
});
GameEvents.Subscribe("ai_lod_ability_offers", RenderAbilityOffers);
GameEvents.Subscribe("lod_draft_phase_start", function (event) {
	RenderAbilityOffers({ basic: event.regular, ultimate: event.ultimate, time: event.time });
});

GameEvents.Subscribe("ai_lod_ability_picked", function (event) {
	var picked = $("#DraftPicked");
	var label = $.CreatePanel("Label", picked, "");
	label.text = "Picked: " + PrettyName(event.ability)
		+ " (" + event.regularCount + "/4"
		+ (event.hasUltimate ? ", ult done" : ", need ult") + ")";
	var btn = abilityDraftPanel.FindChildTraverse("draft_" + event.ability);
	if (btn) btn.SetHasClass("Banned", true);
});
GameEvents.Subscribe("lod_ability_picked", function (event) {
	var btn = abilityDraftPanel.FindChildTraverse("draft_" + event.ability);
	if (btn) btn.SetHasClass("Banned", true);
});

GameEvents.Subscribe("ai_lod_ability_timer", function (event) {
	$("#DraftTimer").text = String(event.time);
});
GameEvents.Subscribe("lod_draft_timer", function (event) {
	$("#DraftTimer").text = String(event.time);
});

GameEvents.Subscribe("ai_lod_ability_draft_end", function () {
	ShowPanel(null);
});
GameEvents.Subscribe("lod_draft_phase_end", function () {
	ShowPanel(null);
});

// ---------------------------------------------------------------------------
// 2nd ultimate draft
// ---------------------------------------------------------------------------
var selectedUlt = null;

GameEvents.Subscribe("ai_lod_ult_draft_start", function (event) {
	ShowPanel(ultDraftPanel);
	if (event.time != null) $("#UltTimer").text = String(event.time);
	selectedUlt = null;
});

GameEvents.Subscribe("ai_lod_ult_offers", function (event) {
	ShowPanel(ultDraftPanel);
	var list = $("#UltChoiceList");
	list.RemoveAndDeleteChildren();
	SplitList(event.choices).forEach(function (ability) {
		var btn = $.CreatePanel("Button", list, "ult_" + ability);
		var label = $.CreatePanel("Label", btn, "");
		label.text = PrettyName(ability);
		if (event.selected === ability) btn.SetHasClass("Selected", true);
		if (event.confirmed) btn.SetHasClass("Banned", true);
		btn.SetPanelEvent("onactivate", (function (a) {
			return function () {
				selectedUlt = a;
				GameEvents.SendCustomGameEventToServer("ai_lod_pick_ult", { ability: a });
				$("#UltSelected").text = "Selected: " + PrettyName(a);
			};
		})(ability));
	});
	if (event.selected) {
		$("#UltSelected").text = "Selected: " + PrettyName(event.selected)
			+ (event.confirmed ? " (LOCKED)" : "");
	}
	if (event.time != null) $("#UltTimer").text = String(event.time);
});

GameEvents.Subscribe("ai_lod_ult_timer", function (event) {
	$("#UltTimer").text = String(event.time);
});

GameEvents.Subscribe("ai_lod_ult_draft_end", function () {
	ShowPanel(null);
});

(function setupUltConfirm() {
	var btn = $("#UltConfirmBtn");
	if (!btn) return;
	btn.SetPanelEvent("onactivate", function () {
		GameEvents.SendCustomGameEventToServer("ai_lod_confirm_ult", {});
	});
})();

// ---------------------------------------------------------------------------
// Death draft
// ---------------------------------------------------------------------------
var deathSlot = null;
var deathAbility = null;

GameEvents.Subscribe("ai_lod_death_draft", function (event) {
	ShowPanel(deathDraftPanel);
	deathSlot = event.selected_slot || null;
	deathAbility = event.selected_ability || null;

	var slots = $("#DeathSlotList");
	slots.RemoveAndDeleteChildren();
	SplitList(event.slots).forEach(function (ability) {
		var btn = $.CreatePanel("Button", slots, "dslot_" + ability);
		var label = $.CreatePanel("Label", btn, "");
		label.text = PrettyName(ability);
		if (deathSlot === ability) btn.SetHasClass("Selected", true);
		btn.SetPanelEvent("onactivate", (function (a) {
			return function () {
				deathSlot = a;
				GameEvents.SendCustomGameEventToServer("ai_lod_death_slot", { slot: a });
			};
		})(ability));
	});

	var offers = $("#DeathOfferList");
	offers.RemoveAndDeleteChildren();
	SplitList(event.offers).forEach(function (ability) {
		var btn = $.CreatePanel("Button", offers, "doffer_" + ability);
		var label = $.CreatePanel("Label", btn, "");
		label.text = PrettyName(ability);
		if (deathAbility === ability) btn.SetHasClass("Selected", true);
		btn.SetPanelEvent("onactivate", (function (a) {
			return function () {
				deathAbility = a;
				GameEvents.SendCustomGameEventToServer("ai_lod_death_ability", { ability: a });
			};
		})(ability));
	});

	$("#DeathRerolls").text = "Rerolls left: " + String(event.rerolls != null ? event.rerolls : 0);
	if (event.time != null) $("#DeathTimer").text = String(event.time);
});

GameEvents.Subscribe("ai_lod_death_timer", function (event) {
	$("#DeathTimer").text = String(event.time);
});

GameEvents.Subscribe("ai_lod_death_end", function (event) {
	ShowPanel(null);
	if (deathrollNotice) {
		deathrollNotice.SetHasClass("Visible", true);
		$("#DeathrollText").text = "Lost: " + PrettyName(event.replaced) + "  Gained: " + PrettyName(event.gained);
		$.Schedule(5, function () {
			deathrollNotice.SetHasClass("Visible", false);
		});
	}
});

(function setupDeathButtons() {
	var r = $("#DeathRerollBtn");
	if (r) {
		r.SetPanelEvent("onactivate", function () {
			GameEvents.SendCustomGameEventToServer("ai_lod_death_reroll", {});
		});
	}
	var c = $("#DeathConfirmBtn");
	if (c) {
		c.SetPanelEvent("onactivate", function () {
			GameEvents.SendCustomGameEventToServer("ai_lod_death_confirm", {});
		});
	}
})();

GameEvents.Subscribe("lod_battle_start", function () {
	HideAllDraftPanels();
});

GameEvents.Subscribe("lod_extra_ult", function (event) {
	$.Msg("Extra ultimate granted: " + event.ability);
});

GameEvents.Subscribe("lod_deathroll", function (event) {
	deathrollNotice.SetHasClass("Visible", true);
	$("#DeathrollText").text = "Lost: " + PrettyName(event.replaced) + "  Gained: " + PrettyName(event.gained);
	$.Schedule(5, function () {
		deathrollNotice.SetHasClass("Visible", false);
	});
});
