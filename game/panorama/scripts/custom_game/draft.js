// Panorama only renders server offers and acknowledgements; never generate picks here.
"use strict";

var currentState = "";
var receivedState = false;
var matchEnded = false;
var resultsClosed = false;
var selectedHero = "";
var selectedBasics = [];
var selectedUltimates = [];
var bannedHeroes = [];
var rosterSnapshot = null;
var preparationSnapshot = null;
var lobbySnapshot = null;
var deathDraftID = null;
var deathSlot = null;
var noticeVersion = 0;
var lanes = { top: "#LaneTop", mid: "#LaneMid", bottom: "#LaneBottom", jungle: "#LaneJungle" };
var phasePanels = {
	LOBBY: "Lobby", BAN_HEROES: "BanPhase", SELECT_BASE_HERO: "HeroSelect",
	ABILITY_DRAFT: "AbilityDraft", INITIAL_ULTIMATE: "InitialUltDraft",
	BONUS_ULTIMATE_DRAFT: "UltDraft", BUILD_CONFIRMATION: "BuildConfirmation",
	STRATEGY_TIME: "Preparation", INTRODUCTION: "Preparation", GAME_START: "Preparation",
	GAME_END: "MatchResults"
};
var aliases = {
	WAITING: "LOBBY", BAN: "BAN_HEROES", HERO_BAN: "BAN_HEROES",
	HERO_SELECT: "SELECT_BASE_HERO", HERO_DRAFT: "SELECT_BASE_HERO",
	ULTIMATE_DRAFT: "BONUS_ULTIMATE_DRAFT", ULT_DRAFT: "BONUS_ULTIMATE_DRAFT",
	STRATEGY: "STRATEGY_TIME", SPAWN: "GAME_START", PLAYING: "GAME", RESPAWN_DRAFT: "GAME", GAME_OVER: "GAME_END"
};

function Canonical(name) { return aliases[name] || name; }
function L(key) {
	var token = "#ai_lod_" + key;
	var localized = $.Localize(token);
	return localized !== token ? localized : key.replace(/^(state|status|error)_/, "").replace(/_/g, " ");
}
function ErrorText(reason) {
	if (!reason) return "";
	var token = "#ai_lod_error_" + reason;
	var localized = $.Localize(token);
	return localized !== token ? localized : L("error_invalid_build");
}
function IsTrue(value) { return value === true || value === 1 || value === "1"; }
function SplitList(value) {
	if (!value) return [];
	if (typeof value === "object") return TableRows(value).filter(function (x) { return !!x; });
	return String(value).split(",").filter(function (x) { return !!x; });
}
function TableRows(value) { return Object.keys(value || {}).map(function (key) { return value[key]; }); }
function PrettyName(id) {
	if (!id) return "";
	var token = String(id).indexOf("npc_dota_hero_") === 0 ? "#" + id : "#DOTA_Tooltip_ability_" + id;
	var localized = $.Localize(token);
	return localized !== token ? localized : String(id).replace(/^npc_dota_hero_/, "").replace(/_/g, " ");
}
function PlayerName(id) { return Players.GetPlayerName(Number(id)) || (L("player") + " " + id); }
function Send(name, data) { GameEvents.SendCustomGameEventToServer(name, data || {}); }
function Text(parent, text, className) {
	var label = $.CreatePanel("Label", parent, "");
	label.text = text;
	if (className) label.AddClass(className);
	return label;
}
function Clear(id) { var panel = $(id); panel.RemoveAndDeleteChildren(); return panel; }
function Timer(id, event) { if (event.time != null) $(id).text = String(Math.max(0, Number(event.time) || 0)); }
function AbilityTooltip(panel, ability) {
	panel.SetPanelEvent("onmouseover", function () { $.DispatchEvent("DOTAShowAbilityTooltip", panel, ability); });
	panel.SetPanelEvent("onmouseout", function () { $.DispatchEvent("DOTAHideAbilityTooltip", panel); });
}
function HeroImage(parent, hero, className) {
	var image = $.CreatePanel("DOTAHeroImage", parent, "");
	image.heroname = hero || "";
	image.heroimagestyle = "landscape";
	image.AddClass(className || "HeroPortrait");
	return image;
}
function AbilityImage(parent, ability) {
	var image = $.CreatePanel("DOTAAbilityImage", parent, "");
	image.abilityname = ability;
	image.AddClass("AbilityIcon");
	AbilityTooltip(image, ability);
	return image;
}
function AbilityCard(parent, ability, enabled, selected, callback) {
	var button = $.CreatePanel("Button", parent, "");
	button.AddClass("AbilityCard");
	AbilityImage(button, ability);
	Text(button, PrettyName(ability), "AbilityName");
	button.enabled = enabled;
	button.SetHasClass("Selected", selected);
	AbilityTooltip(button, ability);
	if (callback) button.SetPanelEvent("onactivate", callback);
	return button;
}
function Action(parent, text, callback, className) {
	var button = $.CreatePanel("Button", parent, "");
	button.AddClass(className || "SmallButton");
	Text(button, text);
	button.SetPanelEvent("onactivate", callback);
	return button;
}
function DraftActive() {
	return ["BAN_HEROES", "GENERATE_HERO_POOLS", "SELECT_BASE_HERO", "ABILITY_DRAFT",
		"INITIAL_ULTIMATE", "BONUS_ULTIMATE_DRAFT", "BUILD_CONFIRMATION", "ABILITY_VALIDATION"].indexOf(currentState) !== -1;
}
function Shell() {
	var full = currentState === "LOBBY" || DraftActive() || currentState === "INTRODUCTION";
	$("#DraftBackdrop").SetHasClass("Visible", full);
	$("#DraftHeader").SetHasClass("Visible", full);
	$("#RadiantRoster").SetHasClass("Visible", DraftActive());
	$("#DireRoster").SetHasClass("Visible", DraftActive());
	$("#ChosenBuild").SetHasClass("Visible", DraftActive());
	$("#Progression").text = L("state_" + currentState.toLowerCase());
}
function HideAll() {
	Object.keys(phasePanels).forEach(function (phase) { $("#" + phasePanels[phase]).SetHasClass("Visible", false); });
	$("#DeathDraft").SetHasClass("Visible", false);
}
function Enter(phase) {
	if (matchEnded && phase !== "GAME_END") return false;
	if (currentState && currentState !== phase) return false;
	HideAll();
	$("#" + phasePanels[phase]).SetHasClass("Visible", true);
	return true;
}
function End(phase) { if (!currentState || currentState === phase) $("#" + phasePanels[phase]).SetHasClass("Visible", false); }

function RenderBuild(id, hero, basic, ultimate, onlyBasics) {
	var parent = Clear(id);
	var heroPanel = $.CreatePanel("Panel", parent, "");
	heroPanel.AddClass("BuildHero");
	HeroImage(heroPanel, hero);
	Text(heroPanel, hero ? PrettyName(hero) : L("base_hero"));
	var slots = basic.slice(0, 3);
	while (slots.length < 3) slots.push("");
	if (!onlyBasics) slots = slots.concat([ultimate[0] || "", ultimate[1] || ""]);
	slots.forEach(function (ability, index) {
		var slot = $.CreatePanel("Panel", parent, "");
		slot.AddClass("BuildSlot");
		if (ability) AbilityImage(slot, ability);
		else $.CreatePanel("Panel", slot, "").AddClass("EmptySlot");
		Text(slot, index < 3 ? L("basic") + " " + (index + 1) : L(index === 3 ? "initial" : "bonus"), "SlotCaption");
	});
}
function UpdateBuild(event) {
	if (event.hero) selectedHero = event.hero;
	if (event.picked_basic != null) selectedBasics = SplitList(event.picked_basic);
	if (event.picked_ultimate != null) selectedUltimates = SplitList(event.picked_ultimate);
	RenderBuild("#ChosenBuildSlots", selectedHero, selectedBasics, selectedUltimates, false);
}
function RenderBans(heroes) {
	bannedHeroes = heroes;
	var parent = Clear("#BannedPortraits");
	heroes.forEach(function (hero) { HeroImage(parent, hero); });
}
function RenderRosterRows(parent, players, team, slots) {
	parent.RemoveAndDeleteChildren();
	var rows = players.filter(function (player) { return Number(player.team) === team; });
	rows.sort(function (a, b) { return Number(a.player_id) - Number(b.player_id); });
	for (var i = 0; i < Math.max(slots || 0, rows.length); i++) {
		var player = rows[i];
		var row = $.CreatePanel("Panel", parent, "");
		row.AddClass("RosterRow");
		HeroImage(row, player && player.hero);
		var details = $.CreatePanel("Panel", row, "");
		details.AddClass("RosterDetails");
		Text(details, player ? PlayerName(player.player_id) : L("open_slot"), "RosterName");
		var status = !player ? "—" : IsTrue(player.ready) ? L("ready")
			: player.draft_state ? L("state_" + Canonical(player.draft_state).toLowerCase()) : L("waiting");
		if (player && lanes[player.lane]) status = L("lane_" + player.lane) + " · " + status;
		if (player && player.basic_count != null) status += "\n" + player.basic_count + "/3 + " + (player.ultimate_count || 0) + "/2";
		Text(details, status, "RosterStatus");
		if (player) row.SetHasClass("LocalPlayer", Number(player.player_id) === Players.GetLocalPlayer());
	}
}
function RenderRoster(event) {
	if (!event) return;
	rosterSnapshot = event;
	if (event.banned != null) RenderBans(SplitList(event.banned));
	var players = TableRows(event.players);
	[2, 3].forEach(function (team) {
		var parent = Clear(team === 2 ? "#RadiantRoster" : "#DireRoster");
		Text(parent, L(team === 2 ? "radiant" : "dire"), "SectionTitle");
		var rows = $.CreatePanel("Panel", parent, "");
		rows.AddClass("PlayerList");
		RenderRosterRows(rows, players, team, 5);
	});
	players.forEach(function (player) {
		if (Number(player.player_id) !== Players.GetLocalPlayer()) return;
		UpdateBuild({ hero: player.hero, picked_basic: player.basic, picked_ultimate: player.ultimate });
	});
}
function RenderLobby(event) {
	lobbySnapshot = event;
	if (!event || !Enter("LOBBY")) return;
	var players = TableRows(event.players);
	RenderRoster(event);
	RenderRosterRows($("#LobbyRadiant"), players, 2, 5);
	RenderRosterRows($("#LobbyDire"), players, 3, 5);
	Timer("#LobbyTimer", event);
	$("#LobbyStatus").text = players.length + "/" + (event.required_players || 10) + " · "
		+ (event.status ? L("status_" + event.status) : L("waiting"));
	var local = players.filter(function (p) { return Number(p.player_id) === Players.GetLocalPlayer(); })[0];
	$("#LobbyReadyBtn").enabled = !!local && !IsTrue(local.ready);
}
GameEvents.Subscribe("ai_lod_lobby", RenderLobby);
GameEvents.Subscribe("ai_lod_roster", RenderRoster);
$("#LobbyReadyBtn").SetPanelEvent("onactivate", function () { Send("ai_lod_lobby_ready", { ready: true }); });
$("#LobbyReadyBtn").enabled = false;

function SetDraftState(event, fromSnapshot) {
	if (!event || !event.name) return;
	var phase = Canonical(event.name);
	var changed = currentState !== phase;
	currentState = phase;
	if (!fromSnapshot) receivedState = true;
	matchEnded = phase === "GAME_END";
	if (changed) {
		HideAll();
		deathDraftID = null;
		deathSlot = null;
		$("#DeathrollNotice").SetHasClass("Visible", false);
		if (phasePanels[phase] && phase !== "GAME_END") $("#" + phasePanels[phase]).SetHasClass("Visible", true);
	}
	Shell();
	if (phase === "LOBBY" && lobbySnapshot) RenderLobby(lobbySnapshot);
	if (preparationSnapshot && Canonical(preparationSnapshot.phase) === phase) RenderPreparation(preparationSnapshot);
}
GameEvents.Subscribe("ai_lod_state", function (event) { SetDraftState(event, false); });
GameEvents.Subscribe("ai_lod_playing", function () {
	if (currentState && currentState !== "GAME") return;
	if (deathDraftID === null) HideAll();
});

GameEvents.Subscribe("ai_lod_ban_start", function (event) {
	if (!Enter("BAN_HEROES")) return;
	RenderBans(SplitList(event.banned));
	var parent = Clear("#BanAbilityList");
	SplitList(event.heroes).forEach(function (hero) {
		var button = $.CreatePanel("Button", parent, "ban_" + hero);
		button.AddClass("BanCard");
		HeroImage(button, hero);
		Text(button, PrettyName(hero));
		var banned = bannedHeroes.indexOf(hero) !== -1;
		button.SetHasClass("Banned", banned);
		button.enabled = !banned && !IsTrue(event.locked);
		button.SetPanelEvent("onactivate", function () { Send("ai_lod_ban_hero", { hero: hero }); });
	});
	Timer("#BanTimer", event);
});
GameEvents.Subscribe("ai_lod_hero_banned", function (event) {
	if (currentState && currentState !== "BAN_HEROES") return;
	if (bannedHeroes.indexOf(event.hero) === -1) RenderBans(bannedHeroes.concat([event.hero]));
	var button = $("#BanPhase").FindChildTraverse("ban_" + event.hero);
	if (button) { button.enabled = false; button.AddClass("Banned"); }
	if (Number(event.playerID) === Players.GetLocalPlayer()) $("#BanAbilityList").Children().forEach(function (b) { b.enabled = false; });
});

function RenderHeroOffers(event) {
	if (!Enter("SELECT_BASE_HERO")) return;
	var parent = Clear("#HeroCategories");
	["strength", "agility", "intelligence"].forEach(function (key, index) {
		var column = $.CreatePanel("Panel", parent, "");
		column.AddClass("HeroCategory");
		Text(column, L(key), "CategoryName");
		var heroes = SplitList(event[key]);
		// Fixed 3 x 4 grid; missing server offers are inert placeholders.
		for (var i = 0; i < 4; i++) {
			(function (hero) {
				var button = $.CreatePanel("Button", column, "");
				button.AddClass("HeroCard");
				HeroImage(button, hero);
				var details = $.CreatePanel("Panel", button, "");
				details.AddClass("HeroDetails");
				Text(details, hero ? PrettyName(hero) : L("waiting"), "HeroName");
				var abilities = $.CreatePanel("Panel", details, "");
				abilities.AddClass("HeroAbilities");
				SplitList(event.hero_abilities && event.hero_abilities[hero]).slice(0, 4).forEach(function (ability) { AbilityImage(abilities, ability); });
				button.enabled = !!hero && !IsTrue(event.locked);
				button.SetHasClass("Selected", !!hero && (event.selected === hero || event.picked === hero));
				button.SetPanelEvent("onactivate", function () { Send("ai_lod_pick_hero", { hero: hero }); });
			})(heroes[i]);
		}
		var count = Number(event[["reroll_str", "reroll_agi", "reroll_int"][index]] || 0);
		var question = $.CreatePanel("Panel", column, "");
		question.AddClass("RerollQuestion");
		question.visible = false;
		var reroll = Action(column, L("reroll") + " · " + count, function () { question.visible = true; }, "RerollButton");
		reroll.enabled = count > 0 && !IsTrue(event.locked);
		Action(question, L("yes"), function () {
			question.visible = false;
			Send("ai_lod_reroll_hero", { category: key });
		}).enabled = reroll.enabled;
		Action(question, L("no"), function () { question.visible = false; });
	});
	Timer("#HeroTimer", event);
	$("#RerollsLeft").text = IsTrue(event.locked) ? L("locked") : L("hero_hint");
	UpdateBuild({ hero: event.selected || event.picked });
}
GameEvents.Subscribe("ai_lod_hero_offers", RenderHeroOffers);
GameEvents.Subscribe("ai_lod_hero_picked", function (event) {
	if (currentState !== "SELECT_BASE_HERO") return;
	UpdateBuild({ hero: event.hero });
	$("#RerollsLeft").text = L("locked") + " · " + PrettyName(event.hero);
	$("#HeroCategories").FindChildrenWithClassTraverse("HeroCard").forEach(function (button) {
		button.enabled = false;
		button.SetHasClass("Selected", button.GetChild(0).heroname === event.hero);
	});
	$("#HeroCategories").FindChildrenWithClassTraverse("RerollButton").forEach(function (button) { button.enabled = false; });
	$("#HeroCategories").FindChildrenWithClassTraverse("RerollQuestion").forEach(function (panel) { panel.visible = false; });
});
GameEvents.Subscribe("ai_lod_ability_offers", function (event) {
	if (!Enter("ABILITY_DRAFT")) return;
	UpdateBuild(event);
	var parent = Clear("#DraftRegularList");
	SplitList(event.basic || event.regular).forEach(function (ability) {
		var selected = selectedBasics.indexOf(ability) !== -1;
		AbilityCard(parent, ability, selectedBasics.length < 3 && !selected && !IsTrue(event.locked), selected,
			function () { Send("ai_lod_pick_ability", { ability: ability }); });
	});
	RenderBuild("#DraftPicked", selectedHero, selectedBasics, [], true);
	Timer("#DraftTimer", event);
});
GameEvents.Subscribe("ai_lod_initial_ult_offers", function (event) {
	if (!Enter("INITIAL_ULTIMATE")) return;
	UpdateBuild(event);
	var parent = Clear("#InitialUltChoices");
	SplitList(event.choices).forEach(function (ability) {
		AbilityCard(parent, ability, !IsTrue(event.locked), event.selected === ability,
			function () { Send("ai_lod_pick_initial_ult", { ability: ability }); });
	});
	$("#InitialUltStatus").text = IsTrue(event.locked) ? L("locked") : L("initial_hint");
	Timer("#InitialUltTimer", event);
});
GameEvents.Subscribe("ai_lod_ult_offers", function (event) {
	if (!Enter("BONUS_ULTIMATE_DRAFT")) return;
	UpdateBuild(event);
	var parent = Clear("#UltChoiceList");
	var choices = SplitList(event.choices);
	var locked = IsTrue(event.confirmed) || IsTrue(event.locked);
	choices.forEach(function (ability) {
		AbilityCard(parent, ability, !locked, event.selected === ability,
			function () { Send("ai_lod_pick_ult", { ability: ability }); });
	});
	$("#UltCount").text = L("bonus_hint") + " · " + choices.length + " " + L("choices");
	$("#UltSelected").text = locked ? L("locked") : event.selected ? PrettyName(event.selected) : L("choose_ultimate");
	$("#UltConfirmBtn").enabled = !!event.selected && !locked;
	Timer("#UltTimer", event);
});
$("#UltConfirmBtn").enabled = false;
$("#UltConfirmBtn").SetPanelEvent("onactivate", function () { Send("ai_lod_confirm_ult"); });
GameEvents.Subscribe("ai_lod_build_confirmation", function (event) {
	if (!Enter("BUILD_CONFIRMATION")) return;
	UpdateBuild({ hero: event.hero, picked_basic: event.basic, picked_ultimate: event.ultimate });
	RenderBuild("#FinalBuild", selectedHero, selectedBasics, selectedUltimates, false);
	$("#BuildError").text = event.error ? ErrorText(event.error) : IsTrue(event.locked) ? L("locked") : "";
	$("#BuildConfirmBtn").enabled = !IsTrue(event.locked) && selectedBasics.length === 3 && selectedUltimates.length === 2;
	Timer("#BuildTimer", event);
});
$("#BuildConfirmBtn").enabled = false;
$("#BuildConfirmBtn").SetPanelEvent("onactivate", function () { Send("ai_lod_confirm_build"); });

[
	["ai_lod_ban", "BAN_HEROES", "#BanTimer", "_start", "_end"],
	["ai_lod_hero", "SELECT_BASE_HERO", "#HeroTimer", "_draft_start", "_draft_end"],
	["ai_lod_ability", "ABILITY_DRAFT", "#DraftTimer", "_draft_start", "_draft_end"],
	["ai_lod_initial_ult", "INITIAL_ULTIMATE", "#InitialUltTimer", "_draft_start", "_end"],
	["ai_lod_ult", "BONUS_ULTIMATE_DRAFT", "#UltTimer", "_draft_start", "_draft_end"],
	["ai_lod_build", "BUILD_CONFIRMATION", "#BuildTimer", null, "_confirmation_end"]
].forEach(function (spec) {
	if (spec[3] && spec[0] !== "ai_lod_ban") GameEvents.Subscribe(spec[0] + spec[3], function (event) {
		if (Enter(spec[1])) Timer(spec[2], event);
	});
	GameEvents.Subscribe("ai_lod_initial_ult_draft_end", function () { End("INITIAL_ULTIMATE"); });
	GameEvents.Subscribe(spec[0] + "_timer", function (event) {
		if (!currentState || currentState === spec[1]) Timer(spec[2], event);
	});
	GameEvents.Subscribe(spec[0] + spec[4], function () { End(spec[1]); });
});

GameEvents.Subscribe("ai_lod_death_draft", function (event) {
	if (matchEnded || (currentState && currentState !== "GAME")) return;
	if (Number(event.time) <= 0) { $("#DeathDraft").SetHasClass("Visible", false); deathDraftID = null; return; }
	deathDraftID = event.draft_id;
	deathSlot = event.selected_slot || null;
	$("#DeathDraft").SetHasClass("Visible", true);
	var basics = SplitList(event.basic_slots);
	var ultimates = SplitList(event.ultimate_slots);
	var pendingBasic = SplitList(event.pending_basic);
	var pendingUlt = SplitList(event.pending_ultimate);
	var loading = IsTrue(event.loading);
	var isBasic = basics.indexOf(deathSlot) !== -1;
	var isUlt = ultimates.indexOf(deathSlot) !== -1;
	var staged = false;
	function Slots(id, originals, pending) {
		var parent = Clear(id);
		originals.forEach(function (ability, index) {
			var replacement = pending[index] || ability;
			staged = staged || replacement !== ability;
			var button = AbilityCard(parent, replacement, !loading, deathSlot === ability, function () {
				Send("ai_lod_death_slot", { slot: ability, draft_id: deathDraftID });
			});
			button.SetHasClass("Staged", replacement !== ability);
		});
	}
	function Offers(id, choices, enabled) {
		var parent = Clear(id);
		parent.visible = enabled;
		choices.forEach(function (ability) {
			AbilityCard(parent, ability, enabled && !loading && pendingBasic.concat(pendingUlt).indexOf(ability) === -1, false, function () {
				Send("ai_lod_death_ability", { ability: ability, draft_id: deathDraftID });
			});
		});
	}
	Slots("#DeathBasicSlots", basics, pendingBasic);
	Slots("#DeathUltimateSlots", ultimates, pendingUlt);
	var basicOffers = SplitList(event.basic_offers);
	var ultOffers = SplitList(event.ultimate_offers);
	Offers("#DeathBasicOffers", basicOffers, isBasic);
	Offers("#DeathUltimateOffers", ultOffers, isUlt);
	$("#DeathOfferTitle").text = L(isBasic ? "basic_replacements" : isUlt ? "ultimate_replacements" : "select_slot");
	$("#DeathEmpty").visible = isBasic ? basicOffers.length === 0 : isUlt ? ultOffers.length === 0 : !basicOffers.length && !ultOffers.length;
	var rerolls = Number(event.rerolls || 0);
	$("#DeathRerolls").text = L("shared_rerolls") + ": " + rerolls + "/3";
	$("#DeathRerollBtn").enabled = rerolls > 0 && !loading;
	$("#DeathKeepSlotBtn").enabled = (isBasic || isUlt) && !loading;
	$("#DeathConfirmBtn").enabled = staged && !loading;
	$("#DeathSkipBtn").enabled = true;
	$("#DeathLoading").visible = loading;
	$("#DeathDraftError").text = ErrorText(event.error);
	Timer("#DeathTimer", event);
});
GameEvents.Subscribe("ai_lod_death_timer", function (event) {
	if (deathDraftID === null || (event.draft_id != null && String(event.draft_id) !== String(deathDraftID))) return;
	Timer("#DeathTimer", event);
	if (Number(event.time) <= 0) { deathDraftID = null; $("#DeathDraft").SetHasClass("Visible", false); }
});
GameEvents.Subscribe("ai_lod_death_end", function (event) {
	if (event.draft_id != null && deathDraftID !== null && String(event.draft_id) !== String(deathDraftID)) return;
	deathDraftID = null;
	deathSlot = null;
	$("#DeathDraft").SetHasClass("Visible", false);
	if (matchEnded || (IsTrue(event.cancelled) && !IsTrue(event.skipped))) return;
	$("#DeathrollText").text = event.replaced ? L("replaced") + ": " + SplitList(event.gained).map(PrettyName).join(", ") : L("loadout_kept");
	$("#DeathrollNotice").SetHasClass("Visible", true);
	var version = ++noticeVersion;
	$.Schedule(5, function () { if (noticeVersion === version) $("#DeathrollNotice").SetHasClass("Visible", false); });
});
[
	["#DeathRerollBtn", "ai_lod_death_reroll"],
	["#DeathConfirmBtn", "ai_lod_death_confirm"],
	["#DeathSkipBtn", "ai_lod_death_skip"]
].forEach(function (spec) {
	$(spec[0]).SetPanelEvent("onactivate", function () { if (deathDraftID !== null) Send(spec[1], { draft_id: deathDraftID }); });
});
$("#DeathKeepSlotBtn").SetPanelEvent("onactivate", function () {
	if (deathDraftID !== null && deathSlot) Send("ai_lod_death_ability", { ability: deathSlot, draft_id: deathDraftID });
});

function RenderPreparation(event) {
	preparationSnapshot = event;
	if (!event) return;
	var phase = Canonical(event.phase);
	if (!phasePanels[phase] || ["STRATEGY_TIME", "INTRODUCTION", "GAME_START"].indexOf(phase) === -1 || !Enter(phase)) return;
	var strategy = phase === "STRATEGY_TIME";
	$("#Preparation").SetHasClass("Introduction", phase === "INTRODUCTION");
	$("#PreparationTitle").text = L(strategy ? "strategy" : phase === "INTRODUCTION" ? "introduction" : "starting");
	$("#PreparationHint").text = L(strategy ? "strategy_hint" : "preparation_hint");
	Timer("#PreparationTimer", event);
	$("#StrategyReadyBtn").visible = strategy;
	$("#StrategyLanes").visible = strategy;
	var ready = typeof event.ready === "object" && event.ready !== null ? event.ready[String(Players.GetLocalPlayer())] : event.ready;
	$("#StrategyReadyBtn").enabled = strategy && !IsTrue(ready);
	var players = TableRows(event.players || (rosterSnapshot && rosterSnapshot.players));
	var localPlayer = null;
	players.forEach(function (player) {
		if (Number(player.player_id) === Players.GetLocalPlayer()) {
			localPlayer = player;
			UpdateBuild({
				hero: player.hero,
				picked_basic: player.basic != null ? player.basic : player.abilities && player.abilities.basic,
				picked_ultimate: player.ultimate != null ? player.ultimate : player.abilities && player.abilities.ultimate
			});
		}
	});
	$("#StrategyGold").visible = strategy && !!localPlayer && (localPlayer.starting_gold != null || localPlayer.gold != null);
	$("#StrategyGold").text = !localPlayer ? "" : L("starting_gold") + ": "
		+ (localPlayer.starting_gold != null ? localPlayer.starting_gold : "—") + " · " + L("available_gold") + ": "
		+ (localPlayer.gold != null ? localPlayer.gold : "—");
	Object.keys(lanes).forEach(function (lane) {
		$(lanes[lane]).enabled = strategy && !!localPlayer;
		$(lanes[lane]).SetHasClass("Selected", !!localPlayer && localPlayer.lane === lane);
	});
	RenderBuild("#StrategyBuild", selectedHero, selectedBasics, selectedUltimates, false);
	var parent = Clear("#IntroductionPlayers");
	[2, 3].forEach(function (team) {
		var column = $.CreatePanel("Panel", parent, "");
		column.AddClass("LobbyTeam");
		Text(column, L(team === 2 ? "radiant" : "dire"), "SectionTitle");
		var rows = $.CreatePanel("Panel", column, "");
		rows.AddClass("PlayerList");
		RenderRosterRows(rows, players, team, 5);
	});
}
GameEvents.Subscribe("ai_lod_preparation", RenderPreparation);
$("#StrategyReadyBtn").SetPanelEvent("onactivate", function () { Send("ai_lod_strategy_ready"); });
Object.keys(lanes).forEach(function (lane) {
	$(lanes[lane]).enabled = false;
	$(lanes[lane]).SetPanelEvent("onactivate", function () {
		if (currentState === "STRATEGY_TIME") Send("ai_lod_strategy_lane", { lane: lane });
	});
});

function RenderResults(event) {
	if (!event) return;
	matchEnded = true;
	currentState = "GAME_END";
	HideAll();
	Shell();
	deathDraftID = null;
	$("#DeathrollNotice").SetHasClass("Visible", false);
	$("#MatchResults").SetHasClass("Visible", !resultsClosed);
	var team = Players.GetTeam(Players.GetLocalPlayer());
	var winner = Number(event.winner);
	$("#ResultTitle").text = event.error ? L("setup_failed") : winner !== 2 && winner !== 3 ? L("match_complete")
		: winner === team ? L("victory") : team === 2 || team === 3 ? L("defeat") : L("match_complete");
	$("#ResultMVP").text = L("mvp") + ": " + (Number(event.mvp) >= 0 ? PlayerName(event.mvp) : "—");
	$("#ResultRunnerUp").text = L("runner_up") + ": " + (Number(event.runner_up) >= 0 ? PlayerName(event.runner_up) : "—");
	var parent = Clear("#ResultRows");
	function Row(values, hero) {
		var row = $.CreatePanel("Panel", parent, "");
		row.AddClass("ScoreRow");
		if (hero) HeroImage(row, hero, "ScorePortrait");
		else $.CreatePanel("Panel", row, "").AddClass("ScorePortrait");
		values.forEach(function (value, index) { Text(row, String(value == null ? "—" : value), index === 0 ? "PlayerColumn" : ""); });
	}
	Row([L("player"), L("team"), "K", "D", "A", L("damage"), L("score")]);
	TableRows(event.players).sort(function (a, b) { return Number(a.rank) - Number(b.rank); }).forEach(function (player) {
		Row([PlayerName(player.player_id) + "\n" + PrettyName(player.hero), L(Number(player.team) === 2 ? "radiant" : "dire"),
			player.kills, player.deaths, player.assists, player.hero_damage, player.score], player.hero);
	});
}
GameEvents.Subscribe("ai_lod_results", RenderResults);
$("#ResultsCloseBtn").SetPanelEvent("onactivate", function () { resultsClosed = true; $("#MatchResults").SetHasClass("Visible", false); });
CustomNetTables.SubscribeNetTableListener("ai_lod_match", function (table, key, data) {
	if (key === "state") SetDraftState(data, true);
	if (key === "results") RenderResults(data);
	if (key === "roster") RenderRoster(data);
	if (key === "lobby") RenderLobby(data);
	if (key === "preparation") RenderPreparation(data);
});
CustomNetTables.SubscribeNetTableListener("ai_lod_roster", function (table, key, data) {
	if (key === "state") RenderRoster(data);
});
HideAll();
RenderRoster(CustomNetTables.GetTableValue("ai_lod_match", "roster"));
lobbySnapshot = CustomNetTables.GetTableValue("ai_lod_match", "lobby");
preparationSnapshot = CustomNetTables.GetTableValue("ai_lod_match", "preparation");
SetDraftState(CustomNetTables.GetTableValue("ai_lod_match", "state"), true);
RenderResults(CustomNetTables.GetTableValue("ai_lod_match", "results"));
UpdateBuild({});
(function RequestState() {
	if (receivedState) return;
	Send("ai_lod_client_ready");
	$.Schedule(2, RequestState);
})();
