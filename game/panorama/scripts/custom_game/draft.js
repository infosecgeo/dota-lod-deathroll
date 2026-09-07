// draft.js
// Panorama client-side logic for the LOD Deathroll draft UI.
"use strict";

var banPhasePanel = $("#BanPhase");
var heroSelectPanel = $("#HeroSelect");
var abilityDraftPanel = $("#AbilityDraft");
var deathrollNotice = $("#DeathrollNotice");

function ShowPanel(panel) {
	[banPhasePanel, heroSelectPanel, abilityDraftPanel].forEach(function (p) {
		if (p) p.SetHasClass("Visible", p === panel);
	});
}


function HideAllDraftPanels() {
	[banPhasePanel, heroSelectPanel, abilityDraftPanel].forEach(function (p) {
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

// ---------------------------------------------------------------------------
// Ban phase
// ---------------------------------------------------------------------------
GameEvents.Subscribe("lod_ban_phase_start", function (event) {
	ShowPanel(banPhasePanel);
	var list = $("#BanAbilityList");
	list.RemoveAndDeleteChildren();
	var abilities = (event.abilities || "").split(",");
	abilities.forEach(function (ability) {
		if (!ability) return;
		var btn = $.CreatePanel("Button", list, "ban_" + ability);
		var label = $.CreatePanel("Label", btn, "");
		label.text = PrettyName(ability);
		btn.SetPanelEvent("onactivate", (function (a) {
			return function () {
				GameEvents.SendCustomGameEventToServer("lod_ban_ability", { ability: a });
				btn.SetHasClass("Banned", true);
			};
		})(ability));
	});
	if (event.time != null) {
		$("#BanTimer").text = String(event.time);
	}
});

GameEvents.Subscribe("lod_ability_banned", function (event) {
	var btn = banPhasePanel.FindChildTraverse("ban_" + event.ability);
	if (btn) btn.SetHasClass("Banned", true);
});

GameEvents.Subscribe("lod_ban_timer", function (event) {
	$("#BanTimer").text = String(event.time);
});

GameEvents.Subscribe("lod_ban_phase_end", function () {
	ShowPanel(null);
});

// ---------------------------------------------------------------------------
// Hero select — 3 categories × 4 heroes each
// ---------------------------------------------------------------------------
GameEvents.Subscribe("lod_hero_offers", function (event) {
	ShowPanel(heroSelectPanel);
	var container = $("#HeroCategories");
	container.RemoveAndDeleteChildren();

	var categories = [
		{ key: "strength", name: "Strength", heroes: (event.strength || "").split(",") },
		{ key: "agility", name: "Agility", heroes: (event.agility || "").split(",") },
		{ key: "intelligence", name: "Intelligence", heroes: (event.intelligence || "").split(",") },
	];

	categories.forEach(function (cat) {
		var panel = $.CreatePanel("Panel", container, "cat_" + cat.key);
		panel.AddClass("HeroCategory");
		var title = $.CreatePanel("Label", panel, "");
		title.AddClass("CategoryName");
		title.text = cat.name;

		cat.heroes.forEach(function (hero) {
			if (!hero) return;
			var btn = $.CreatePanel("Button", panel, "hero_" + hero);
			var label = $.CreatePanel("Label", btn, "");
			label.text = PrettyName(hero);
			btn.SetPanelEvent("onactivate", (function (h, button) {
				return function () {
					GameEvents.SendCustomGameEventToServer("lod_pick_hero", { hero: h });
					button.SetHasClass("Selected", true);
				};
			})(hero, btn));
		});
	});

	if (event.time != null) {
		$("#HeroTimer").text = String(event.time);
	}
	var rerolls = $("#RerollsLeft");
	if (rerolls) rerolls.text = "Pick 1 hero from the 3×4 pool";
});

GameEvents.Subscribe("lod_hero_picked", function (event) {
	var notice = $("#RerollsLeft");
	if (notice) notice.text = "Picked: " + PrettyName(event.hero);
});

GameEvents.Subscribe("lod_hero_timer", function (event) {
	$("#HeroTimer").text = String(event.time);
});

GameEvents.Subscribe("lod_hero_phase_end", function () {
	ShowPanel(null);
});

// ---------------------------------------------------------------------------
// Ability draft
// ---------------------------------------------------------------------------
GameEvents.Subscribe("lod_draft_phase_start", function (event) {
	ShowPanel(abilityDraftPanel);

	var regular = $("#DraftRegularList");
	regular.RemoveAndDeleteChildren();
	(event.regular || "").split(",").forEach(function (ability) {
		if (!ability) return;
		AddDraftButton(regular, ability);
	});

	var ultimate = $("#DraftUltimateList");
	ultimate.RemoveAndDeleteChildren();
	var ultLabel = $.CreatePanel("Label", ultimate, "ult_header");
	ultLabel.AddClass("CategoryName");
	ultLabel.text = "Ultimates (pick 1)";
	(event.ultimate || "").split(",").forEach(function (ability) {
		if (!ability) return;
		AddDraftButton(ultimate, ability);
	});

	$("#DraftPicked").RemoveAndDeleteChildren();
	var hint = $.CreatePanel("Label", $("#DraftPicked"), "draft_hint");
	hint.text = "Pick 4 regular abilities + 1 ultimate";
	if (event.time != null) {
		$("#DraftTimer").text = String(event.time);
	}
});

function AddDraftButton(parent, ability) {
	var btn = $.CreatePanel("Button", parent, "draft_" + ability);
	var label = $.CreatePanel("Label", btn, "");
	label.text = PrettyName(ability);
	btn.SetPanelEvent("onactivate", (function (a) {
		return function () {
			GameEvents.SendCustomGameEventToServer("lod_pick_ability", { ability: a });
		};
	})(ability));
}

GameEvents.Subscribe("lod_ability_picked", function (event) {
	var picked = $("#DraftPicked");
	var label = $.CreatePanel("Label", picked, "");
	label.text = "Picked: " + PrettyName(event.ability)
		+ " (" + event.regularCount + "/4"
		+ (event.hasUltimate ? ", ult done" : ", need ult") + ")";
	var btn = abilityDraftPanel.FindChildTraverse("draft_" + event.ability);
	if (btn) btn.SetHasClass("Banned", true);
});

GameEvents.Subscribe("lod_draft_timer", function (event) {
	$("#DraftTimer").text = String(event.time);
});

GameEvents.Subscribe("lod_draft_phase_end", function () {
	ShowPanel(null);
});

GameEvents.Subscribe("lod_battle_start", function () {
	ShowPanel(null);
});

// ---------------------------------------------------------------------------
// Extra ultimate + deathroll
// ---------------------------------------------------------------------------
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
