// draft.js
// Panorama client-side logic for the LOD Deathroll draft UI.
"use strict";

var banPhasePanel = $("#BanPhase");
var heroSelectPanel = $("#HeroSelect");
var abilityDraftPanel = $("#AbilityDraft");
var deathrollNotice = $("#DeathrollNotice");

function ShowPanel(panel) {
	[banPhasePanel, heroSelectPanel, abilityDraftPanel].forEach(function (p) {
		p.SetHasClass("Visible", p === panel);
	});
}

// ---------------------------------------------------------------------------
// Ban phase
// ---------------------------------------------------------------------------
GameEvents.Subscribe("lod_ban_phase_start", function (event) {
	ShowPanel(banPhasePanel);
	var list = $("#BanAbilityList");
	list.RemoveAndDeleteChildren();
	event.abilities.split(",").forEach(function (ability) {
		if (!ability) return;
		var btn = $.CreatePanel("Button", list, "ban_" + ability);
		var label = $.CreatePanel("Label", btn, "");
		label.text = ability;
		btn.SetPanelEvent("onactivate", (function (a) {
			return function () {
				GameEvents.SendCustomGameEventToServer("lod_ban_ability", { ability: a });
				btn.SetHasClass("Banned", true);
			};
		})(ability));
	});
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
// Hero select
// ---------------------------------------------------------------------------
GameEvents.Subscribe("lod_hero_offers", function (event) {
	ShowPanel(heroSelectPanel);
	var container = $("#HeroCategories");
	container.RemoveAndDeleteChildren();

	var categories = [
		{ key: "strength", name: "Strength", hero: event.strength },
		{ key: "agility", name: "Agility", hero: event.agility },
		{ key: "intelligence", name: "Intelligence", hero: event.intelligence },
		{ key: "universal", name: "Universal", hero: event.universal },
	];

	categories.forEach(function (cat) {
		if (!cat.hero) return;
		var panel = $.CreatePanel("Panel", container, "cat_" + cat.key);
		panel.AddClass("HeroCategory");
		var title = $.CreatePanel("Label", panel, "");
		title.AddClass("CategoryName");
		title.text = cat.name;
		var btn = $.CreatePanel("Button", panel, "hero_" + cat.key);
		var label = $.CreatePanel("Label", btn, "");
		label.text = cat.hero;
		btn.SetPanelEvent("onactivate", function () {
			GameEvents.SendCustomGameEventToServer("lod_pick_hero", { category: cat.name });
		});
	});

	$("#RerollsLeft").text = "Rerolls left: " + event.rerolls;
});

function OnReroll() {
	GameEvents.SendCustomGameEventToServer("lod_reroll_hero", {});
}

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
	event.regular.split(",").forEach(function (ability) {
		if (!ability) return;
		AddDraftButton(regular, ability);
	});

	var ultimate = $("#DraftUltimateList");
	ultimate.RemoveAndDeleteChildren();
	event.ultimate.split(",").forEach(function (ability) {
		if (!ability) return;
		AddDraftButton(ultimate, ability);
	});

	$("#DraftPicked").RemoveAndDeleteChildren();
});

function AddDraftButton(parent, ability) {
	var btn = $.CreatePanel("Button", parent, "draft_" + ability);
	var label = $.CreatePanel("Label", btn, "");
	label.text = ability;
	btn.SetPanelEvent("onactivate", (function (a) {
		return function () {
			GameEvents.SendCustomGameEventToServer("lod_pick_ability", { ability: a });
		};
	})(ability));
}

GameEvents.Subscribe("lod_ability_picked", function (event) {
	var picked = $("#DraftPicked");
	var label = $.CreatePanel("Label", picked, "");
	label.text = "Picked: " + event.ability;
});

GameEvents.Subscribe("lod_draft_timer", function (event) {
	$("#DraftTimer").text = String(event.time);
});

GameEvents.Subscribe("lod_draft_phase_end", function () {
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
	$("#DeathrollText").text = "Lost: " + event.replaced + "  Gained: " + event.gained;
	$.Schedule(5, function () {
		deathrollNotice.SetHasClass("Visible", false);
	});
});
