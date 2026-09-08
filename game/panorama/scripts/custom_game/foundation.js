// Non-interactive state badge; restore it from the authoritative nettable.
"use strict";

var badge = $("#StateBadge");
var label = $("#StateLabel");
var stateAliases = {
	WAITING: "LOBBY", BAN: "BAN_HEROES", HERO_BAN: "BAN_HEROES",
	HERO_SELECT: "SELECT_BASE_HERO", HERO_DRAFT: "SELECT_BASE_HERO",
	ULTIMATE_DRAFT: "BONUS_ULTIMATE_DRAFT", ULT_DRAFT: "BONUS_ULTIMATE_DRAFT",
	STRATEGY: "STRATEGY_TIME", SPAWN: "GAME_START", PLAYING: "GAME", RESPAWN_DRAFT: "GAME", GAME_OVER: "GAME_END"
};

function SetState(event) {
	var name = event && event.name || "LOBBY";
	name = stateAliases[name] || name;
	if (label) label.text = "AI-LOD · " + $.Localize("#ai_lod_state_" + name.toLowerCase());
	if (badge) badge.SetHasClass("Hidden", name === "GAME" || name === "GAME_END");
}

GameEvents.Subscribe("ai_lod_state", SetState);
GameEvents.Subscribe("ai_lod_playing", function () { SetState({ name: "GAME" }); });
CustomNetTables.SubscribeNetTableListener("ai_lod_match", function (table, key, data) {
	if (key === "state") SetState(data);
});
SetState(CustomNetTables.GetTableValue("ai_lod_match", "state"));
