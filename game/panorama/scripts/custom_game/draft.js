// draft.js — full LOD draft UI (ban / hero / ability / ult / death)
"use strict";

var banPhasePanel = $("#BanPhase");
var heroSelectPanel = $("#HeroSelect");
var abilityDraftPanel = $("#AbilityDraft");
var ultDraftPanel = $("#UltDraft");
var deathDraftPanel = $("#DeathDraft");
var deathrollNotice = $("#DeathrollNotice");
var preparationPanel = $("#Preparation");
var resultsPanel = $("#MatchResults");
var receivedState = false;
var matchEnded = false;
var resultsReceived = false;

function DraftPanels() {
	return [banPhasePanel, heroSelectPanel, abilityDraftPanel, ultDraftPanel,
		deathDraftPanel, preparationPanel, resultsPanel];
}

function ShowPanel(panel) {
	if (matchEnded && panel !== resultsPanel && panel !== null) return;
	DraftPanels().forEach(function (p) {
		if (p) p.SetHasClass("Visible", p === panel);
	});
}

function HideAllDraftPanels() {
	DraftPanels().forEach(function (p) {
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

function TableRows(value) {
	return Object.keys(value || {}).map(function (key) { return value[key]; });
}

function PlayerName(id) {
	return Players.GetPlayerName(Number(id)) || ("Player " + String(id));
}

function IsTrue(value) {
	return value === true || value === 1 || value === "1";
}

function AbilityTooltip(button, ability) {
	button.SetPanelEvent("onmouseover", function () {
		$.DispatchEvent("DOTAShowAbilityTooltip", button, ability);
	});
	button.SetPanelEvent("onmouseout", function () {
		$.DispatchEvent("DOTAHideAbilityTooltip", button);
	});
}

// ---------------------------------------------------------------------------
// State-driven hide when playing
// ---------------------------------------------------------------------------
GameEvents.Subscribe("ai_lod_state", function (event) {
	if (!event || !event.name) return;
	receivedState = true;
	if (event.name === "GAME_OVER") {
		matchEnded = true;
		if (deathrollNotice) deathrollNotice.SetHasClass("Visible", false);
		if (!resultsPanel.BHasClass("Visible")) HideAllDraftPanels();
		return;
	}
	if (event.name === "PLAYING" || event.name === "SPAWN" || event.name === "GAME_OVER") {
		if (event.name !== "PLAYING") HideAllDraftPanels();
		// death draft may still show during PLAYING
		if (event.name !== "PLAYING") {
			if (deathDraftPanel) deathDraftPanel.SetHasClass("Visible", false);
		}
	}
});

GameEvents.Subscribe("ai_lod_playing", function () {
	if (matchEnded) return;
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
		var banned = SplitList(event.banned).indexOf(hero) !== -1;
		btn.enabled = !banned && !IsTrue(event.locked);
		btn.SetHasClass("Banned", banned);
		btn.SetPanelEvent("onactivate", (function (h) {
			return function () {
				GameEvents.SendCustomGameEventToServer("ai_lod_ban_hero", { hero: h });
			};
		})(hero));
	});
	if (event.time != null) {
		$("#BanTimer").text = String(event.time);
	}
});

GameEvents.Subscribe("ai_lod_hero_banned", function (event) {
	var btn = banPhasePanel.FindChildTraverse("ban_" + event.hero);
	if (btn) {
		btn.SetHasClass("Banned", true);
		btn.enabled = false;
	}
	if (Number(event.playerID) === Players.GetLocalPlayer()) {
		$("#BanAbilityList").Children().forEach(function (button) { button.enabled = false; });
	}
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
			btn.enabled = !IsTrue(event.locked);
			btn.SetHasClass("Selected", event.selected === hero || event.picked === hero);
			btn.SetPanelEvent("onactivate", (function (h, button) {
				return function () {
					GameEvents.SendCustomGameEventToServer("ai_lod_pick_hero", { hero: h });
				};
			})(hero, btn));
		});

		var rerollBtn = $.CreatePanel("Button", panel, "reroll_" + cat.key);
		rerollBtn.AddClass("RerollButton");
		var rLabel = $.CreatePanel("Label", rerollBtn, "");
		rLabel.text = "Reroll (" + String(cat.rerolls != null ? cat.rerolls : 0) + ")";
		rerollBtn.enabled = Number(cat.rerolls || 0) > 0 && !IsTrue(event.locked);
		if (!rerollBtn.enabled) {
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
	$("#HeroCategories").FindChildrenWithClassTraverse("HeroCategory").forEach(function (category) {
		category.Children().forEach(function (child) {
			if (child.paneltype === "Button") {
				child.enabled = false;
				child.SetHasClass("Selected", child.id === "hero_" + event.hero);
			}
		});
	});
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
	var pb = SplitList(event.picked_basic);
	var pu = SplitList(event.picked_ultimate);

	var regular = $("#DraftRegularList");
	regular.RemoveAndDeleteChildren();
	SplitList(event.basic || event.regular).forEach(function (ability) {
		AddDraftButton(regular, ability, pb.length < 3 && pb.indexOf(ability) === -1 && !IsTrue(event.locked));
	});

	var ultimate = $("#DraftUltimateList");
	ultimate.RemoveAndDeleteChildren();
	SplitList(event.ultimate).forEach(function (ability) {
		AddDraftButton(ultimate, ability, pb.length === 3 && pu.length === 0 && !IsTrue(event.locked));
	});

	$("#DraftPicked").RemoveAndDeleteChildren();
	var hint = $.CreatePanel("Label", $("#DraftPicked"), "draft_hint");
	hint.text = "Basics " + pb.length + "/3: " + pb.map(PrettyName).join(", ")
		+ "\nInitial ultimate " + pu.length + "/1: " + pu.map(PrettyName).join(", ")
		+ (pb.length < 3 ? "\nChoose your three basics first." : "");
	if (event.time != null) {
		$("#DraftTimer").text = String(event.time);
	}
}

function AddDraftButton(parent, ability, enabled) {
	var btn = $.CreatePanel("Button", parent, "draft_" + ability);
	var label = $.CreatePanel("Label", btn, "");
	label.text = PrettyName(ability);
	btn.enabled = enabled;
	AbilityTooltip(btn, ability);
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
		+ " (" + event.regularCount + "/3"
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
GameEvents.Subscribe("ai_lod_ult_draft_start", function (event) {
	ShowPanel(ultDraftPanel);
	if (event.time != null) $("#UltTimer").text = String(event.time);
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
		btn.enabled = !IsTrue(event.confirmed);
		AbilityTooltip(btn, ability);
		btn.SetPanelEvent("onactivate", (function (a) {
			return function () {
				GameEvents.SendCustomGameEventToServer("ai_lod_pick_ult", { ability: a });
			};
		})(ability));
	});
	$("#UltSelected").text = event.selected ? "Selected: " + PrettyName(event.selected)
		+ (IsTrue(event.confirmed) ? " (LOCKED — waiting for other players)" : "") : "Choose an ultimate.";
	$("#UltConfirmBtn").enabled = !!event.selected && !IsTrue(event.confirmed);
	$("#UltCloseBtn").enabled = IsTrue(event.confirmed);
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
	btn.enabled = false;
	$("#UltCloseBtn").SetPanelEvent("onactivate", function () {
		ultDraftPanel.SetHasClass("Visible", false);
	});
})();

// ---------------------------------------------------------------------------
// Death draft
// ---------------------------------------------------------------------------
var deathSlot = null;
var deathDraftID = null;

GameEvents.Subscribe("ai_lod_death_draft", function (event) {
	if (matchEnded) return;
	ShowPanel(deathDraftPanel);
	deathDraftID = event.draft_id;
	deathSlot = event.selected_slot || null;
	var basicSlots = SplitList(event.basic_slots);
	var ultSlots = SplitList(event.ultimate_slots);
	var pendingBasic = SplitList(event.pending_basic);
	var pendingUlt = SplitList(event.pending_ultimate);
	var isBasic = basicSlots.indexOf(deathSlot) !== -1;
	var isUlt = ultSlots.indexOf(deathSlot) !== -1;

	function RenderSlots(id, originals, pending) {
		var parent = $(id);
		parent.RemoveAndDeleteChildren();
		originals.forEach(function (ability, index) {
			var btn = $.CreatePanel("Button", parent, "dslot_" + ability);
			var label = $.CreatePanel("Label", btn, "");
			var replacement = pending[index] || ability;
			label.text = PrettyName(ability) + (replacement !== ability ? " → " + PrettyName(replacement) : "");
			btn.SetHasClass("Selected", deathSlot === ability);
			AbilityTooltip(btn, replacement);
			btn.SetPanelEvent("onactivate", function () {
				GameEvents.SendCustomGameEventToServer("ai_lod_death_slot", {
					slot: ability, draft_id: deathDraftID,
				});
			});
		});
	}

	function RenderOffers(id, choices, enabled) {
		var parent = $(id);
		parent.RemoveAndDeleteChildren();
		parent.visible = enabled;
		choices.forEach(function (ability) {
			var btn = $.CreatePanel("Button", parent, "doffer_" + ability);
			var label = $.CreatePanel("Label", btn, "");
			label.text = PrettyName(ability);
			btn.enabled = enabled && pendingBasic.concat(pendingUlt).indexOf(ability) === -1;
			AbilityTooltip(btn, ability);
			btn.SetPanelEvent("onactivate", function () {
				GameEvents.SendCustomGameEventToServer("ai_lod_death_ability", {
					ability: ability, draft_id: deathDraftID,
				});
			});
		});
	}

	RenderSlots("#DeathBasicSlots", basicSlots, pendingBasic);
	RenderSlots("#DeathUltimateSlots", ultSlots, pendingUlt);
	RenderOffers("#DeathBasicOffers", SplitList(event.basic_offers), isBasic);
	RenderOffers("#DeathUltimateOffers", SplitList(event.ultimate_offers), isUlt);
	$("#DeathOfferTitle").text = isBasic ? "Basic replacements" : isUlt ? "Ultimate replacements"
		: "Select a slot to see replacement offers";
	var rerolls = Number(event.rerolls || 0);
	$("#DeathRerolls").text = "Shared rerolls left: " + rerolls + (rerolls === 0 ? " — rerolls locked; you can still choose and confirm" : "");
	$("#DeathRerollBtn").enabled = rerolls > 0;
	$("#DeathRerollLabel").text = rerolls > 0 ? "Reroll both pools" : "Rerolls locked";
	$("#DeathDraftError").text = event.error ? "Cannot confirm: " + PrettyName(event.error)
		+ ". Revise your staged choices or wait to retain your original kit." : "";
	$("#DeathConfirmBtn").enabled = true;
	$("#DeathKeepSlotBtn").enabled = isBasic || isUlt;
	if (event.time != null) $("#DeathTimer").text = String(event.time);
});

GameEvents.Subscribe("ai_lod_death_timer", function (event) {
	$("#DeathTimer").text = String(event.time);
});

GameEvents.Subscribe("ai_lod_death_end", function (event) {
	deathDraftID = null;
	deathDraftPanel.SetHasClass("Visible", false);
	if (matchEnded || IsTrue(event.cancelled)) return;
	if (deathrollNotice) {
		deathrollNotice.SetHasClass("Visible", true);
		$("#DeathrollText").text = IsTrue(event.timed_out) ? "Time expired — original loadout retained."
			: event.replaced ? "Replaced: " + SplitList(event.replaced).map(PrettyName).join(", ")
				+ "\nWith: " + SplitList(event.gained).map(PrettyName).join(", ")
				: "Loadout retained.";
		$.Schedule(5, function () {
			deathrollNotice.SetHasClass("Visible", false);
		});
	}
});

(function setupDeathButtons() {
	$("#DeathKeepSlotBtn").SetPanelEvent("onactivate", function () {
		GameEvents.SendCustomGameEventToServer("ai_lod_death_ability", {
			ability: deathSlot, draft_id: deathDraftID,
		});
	});
	var r = $("#DeathRerollBtn");
	if (r) {
		r.SetPanelEvent("onactivate", function () {
			GameEvents.SendCustomGameEventToServer("ai_lod_death_reroll", { draft_id: deathDraftID });
		});
	}
	var c = $("#DeathConfirmBtn");
	if (c) {
		c.SetPanelEvent("onactivate", function () {
			GameEvents.SendCustomGameEventToServer("ai_lod_death_confirm", { draft_id: deathDraftID });
		});
	}
})();

GameEvents.Subscribe("lod_battle_start", function () {
	if (matchEnded) return;
	HideAllDraftPanels();
});

GameEvents.Subscribe("lod_extra_ult", function (event) {
	$.Msg("Extra ultimate granted: " + event.ability);
});

GameEvents.Subscribe("lod_deathroll", function (event) {
	if (matchEnded) return;
	deathrollNotice.SetHasClass("Visible", true);
	$("#DeathrollText").text = "Lost: " + PrettyName(event.replaced) + "  Gained: " + PrettyName(event.gained);
	$.Schedule(5, function () {
		deathrollNotice.SetHasClass("Visible", false);
	});
});

GameEvents.Subscribe("ai_lod_preparation", function (event) {
	if (matchEnded) return;
	ShowPanel(preparationPanel);
	var strategy = event.phase === "STRATEGY";
	$("#PreparationTitle").text = strategy ? "Strategy — buy starting items"
		: event.phase === "INTRODUCTION" ? "Player introduction" : "Waiting for players";
	$("#PreparationTimer").text = event.time != null ? String(event.time) : "";
	$("#PreparationHint").text = strategy
		? "Use the normal shop. Your hero and purchased items carry into gameplay."
		: "Gameplay starts after preparation and player readiness checks.";
	$("#StrategyReadyBtn").visible = strategy;
	var ready = typeof event.ready === "object" && event.ready !== null
		? event.ready[String(Players.GetLocalPlayer())] : event.ready;
	$("#StrategyReadyBtn").enabled = strategy && !IsTrue(ready);
	var roster = $("#IntroductionPlayers");
	roster.RemoveAndDeleteChildren();
	if (!strategy) {
		TableRows(event.players).forEach(function (player) {
			var label = $.CreatePanel("Label", roster, "");
			label.AddClass("PhaseHint");
			label.text = PlayerName(player.player_id) + " — " + PrettyName(player.hero);
		});
	}
});

$("#StrategyReadyBtn").SetPanelEvent("onactivate", function () {
	GameEvents.SendCustomGameEventToServer("ai_lod_strategy_ready", {});
});

function RenderResults(event) {
	if (!event || resultsReceived) return;
	resultsReceived = true;
	matchEnded = true;
	ShowPanel(resultsPanel);
	if (deathrollNotice) deathrollNotice.SetHasClass("Visible", false);
	var localTeam = Players.GetTeam(Players.GetLocalPlayer());
	var winner = Number(event.winner);
	$("#ResultTitle").text = winner !== 2 && winner !== 3 ? "MATCH COMPLETE"
		: winner === localTeam ? "VICTORY" : localTeam === 2 || localTeam === 3 ? "DEFEAT" : "MATCH COMPLETE";
	if (event.error) $("#ResultTitle").text = "SETUP FAILED — " + PrettyName(event.error);
	$("#ResultMVP").text = Number(event.mvp) >= 0 ? "MVP: " + PlayerName(event.mvp) : "MVP: —";
	$("#ResultRunnerUp").text = Number(event.runner_up) >= 0 ? "Next MVP: " + PlayerName(event.runner_up) : "Next MVP: —";
	var container = $("#ResultRows");
	container.RemoveAndDeleteChildren();
	function Row(values) {
		var row = $.CreatePanel("Panel", container, "");
		row.AddClass("ScoreRow");
		values.forEach(function (value, index) {
			var label = $.CreatePanel("Label", row, "");
			if (index === 0) label.AddClass("PlayerColumn");
			label.text = String(value);
		});
	}
	Row(["Player / Hero", "Team", "K", "D", "A", "Damage", "Score"]);
	TableRows(event.players).sort(function (a, b) { return Number(a.rank) - Number(b.rank); }).forEach(function (player) {
		Row([PlayerName(player.player_id) + "\n" + PrettyName(player.hero),
			Number(player.team) === 2 ? "Radiant" : "Dire",
			player.kills, player.deaths, player.assists, player.hero_damage, player.score]);
	});
}

GameEvents.Subscribe("ai_lod_results", RenderResults);
CustomNetTables.SubscribeNetTableListener("ai_lod_match", function (table, key, data) {
	if (key === "results") RenderResults(data);
});

$("#ResultsCloseBtn").SetPanelEvent("onactivate", function () {
	resultsPanel.SetHasClass("Visible", false);
});

(function RequestState() {
	if (receivedState) return;
	GameEvents.SendCustomGameEventToServer("ai_lod_client_ready", {});
	$.Schedule(2, RequestState);
})();

RenderResults(CustomNetTables.GetTableValue("ai_lod_match", "results"));
