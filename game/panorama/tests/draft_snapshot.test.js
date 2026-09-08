"use strict";

// Run with node. This tests snapshot rendering, not the Source 2 layout engine.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const root = path.join(__dirname, "..");
const layout = fs.readFileSync(path.join(root, "layout/custom_game/draft/draft.xml"), "utf8");
const script = fs.readFileSync(path.join(root, "scripts/custom_game/draft.js"), "utf8");
const panels = {};
const handlers = {};
const sent = [];
const scheduled = [];
class Panel {
	constructor(type, id) {
		this.paneltype = type;
		this.id = id;
		this.children = [];
		this.classes = new Set();
		this.events = {};
		this.enabled = true;
		this.visible = true;
		if (id) panels[id] = this;
	}
	AddClass(name) { this.classes.add(name); }
	SetHasClass(name, value) { if (value) this.classes.add(name); else this.classes.delete(name); }
	BHasClass(name) { return this.classes.has(name); }
	SetPanelEvent(name, callback) { this.events[name] = callback; }
	RemoveAndDeleteChildren() { this.children = []; }
	Children() { return this.children; }
	GetChild(index) { return this.children[index]; }
	FindChildTraverse(id) { return panels[id]; }
	FindChildrenWithClassTraverse(name) {
		return this.children.flatMap(child => (child.BHasClass(name) ? [child] : []).concat(child.FindChildrenWithClassTraverse(name)));
	}
}
for (const match of layout.matchAll(/\bid="([^"]+)"/g)) new Panel("Panel", match[1]);
const $ = selector => {
	assert.ok(panels[selector.slice(1)], "Unknown layout panel " + selector);
	return panels[selector.slice(1)];
};
$.CreatePanel = (type, parent, id) => { const panel = new Panel(type, id); parent.children.push(panel); return panel; };
$.Localize = token => token;
$.DispatchEvent = () => {};
$.Schedule = (time, callback) => scheduled.push(callback);
const context = vm.createContext({
	$, GameEvents: {
		Subscribe: (name, callback) => { (handlers[name] ||= []).push(callback); },
		SendCustomGameEventToServer: (name, data) => sent.push({ name, data })
	},
	Players: { GetLocalPlayer: () => 0, GetPlayerName: id => "Player " + id, GetTeam: () => 2 },
	CustomNetTables: { SubscribeNetTableListener: () => {}, GetTableValue: () => undefined }
});
vm.runInContext(script, context);
function emit(name, data = {}) { assert.ok(handlers[name], "Missing event " + name); handlers[name].forEach(callback => callback(data)); }
function state(name) { emit("ai_lod_state", { name }); }
function shown(id) { return panels[id].BHasClass("Visible"); }
function click(panel) { assert.ok(panel.enabled); panel.events.onactivate(); }

assert.equal(sent[0].name, "ai_lod_client_ready");
state("LOBBY");
emit("ai_lod_lobby", { players: [{ player_id: 0, team: 2, ready: false }], required_players: 10, time: 20 });
assert.equal(panels.LobbyRadiant.children.length, 5);
assert.equal(panels.LobbyDire.children.length, 5);
click(panels.LobbyReadyBtn);
assert.equal(sent.at(-1).name, "ai_lod_lobby_ready");
assert.equal(sent.at(-1).data.ready, true);
// Ban start is authoritative even if the state event was dropped.
vm.runInContext('currentState = "LOBBY";', context);
emit("ai_lod_ban_start", {
	time: 50,
	heroes: "npc_dota_hero_axe,npc_dota_hero_lina",
	banned: "",
	locked: false
});
assert.ok(shown("BanPhase"), "ban panel opens from ban_start");
assert.ok(!shown("HeroSelect"), "hero select stays closed during ban");
assert.equal(panels.BanAbilityList.children.length, 2);
emit("ai_lod_hero_offers", { strength: "axe" });
assert.ok(shown("BanPhase"), "hero offers cannot skip the ban phase");
assert.ok(!shown("HeroSelect"), "ban must complete before hero select");
state("SELECT_BASE_HERO");
emit("ai_lod_roster", { players: [], banned: "npc_dota_hero_lina,npc_dota_hero_zeus" });
assert.equal(panels.BannedPortraits.children.length, 2, "Roster snapshots restore bans after reconnect");
emit("ai_lod_hero_offers", {
	strength: "axe,sven,tiny,kunkka,ignored", agility: "antimage", intelligence: "",
	reroll_str: 1, reroll_agi: 1, reroll_int: 0, hero_abilities: { axe: "axe_berserkers_call" }
});
assert.equal(panels.HeroCategories.children.length, 3);
assert.equal(panels.HeroCategories.FindChildrenWithClassTraverse("HeroCard").length, 12);
const strength = panels.HeroCategories.children[0];
const beforeReroll = sent.length;
click(strength.FindChildrenWithClassTraverse("RerollButton")[0]);
assert.equal(sent.length, beforeReroll, "Reroll requires YES");
const question = strength.FindChildrenWithClassTraverse("RerollQuestion")[0];
click(question.children[1]);
assert.equal(sent.length, beforeReroll, "NO keeps offers");
click(strength.FindChildrenWithClassTraverse("RerollButton")[0]);
click(question.children[0]);
assert.equal(sent.at(-1).name, "ai_lod_reroll_hero");
assert.equal(sent.at(-1).data.category, "strength");
state("ABILITY_DRAFT");
emit("ai_lod_ability_offers", { basic: "a,b,c,d", picked_basic: "a,b,c", picked_ultimate: "" });
assert.equal(panels.DraftPicked.FindChildrenWithClassTraverse("BuildSlot").length, 3);
assert.ok(panels.DraftRegularList.children.every(button => !button.enabled));
emit("ai_lod_hero_offers", { strength: "stale" });
assert.ok(shown("AbilityDraft"));
assert.ok(!shown("HeroSelect"), "Stale offers must not reopen previous phases");
state("INITIAL_ULTIMATE");
emit("ai_lod_initial_ult_offers", { choices: "u1,u2", picked_basic: "a,b,c", picked_ultimate: "", locked: false });
click(panels.InitialUltChoices.children[0]);
assert.equal(sent.at(-1).name, "ai_lod_pick_initial_ult");
state("BONUS_ULTIMATE_DRAFT");
emit("ai_lod_initial_ult_end");
emit("ai_lod_ult_offers", { choices: "u2,u3,u4,u5,u6", selected: "u2", confirmed: false });
assert.ok(shown("UltDraft"));
assert.equal(panels.UltChoiceList.children.length, 5);
click(panels.UltConfirmBtn);
assert.equal(sent.at(-1).name, "ai_lod_confirm_ult");
state("BUILD_CONFIRMATION");
emit("ai_lod_build_confirmation", { hero: "npc_dota_hero_axe", basic: "a,b,c", ultimate: "u1,u2", locked: false });
assert.equal(panels.FinalBuild.FindChildrenWithClassTraverse("BuildSlot").length, 5);
click(panels.BuildConfirmBtn);
assert.equal(sent.at(-1).name, "ai_lod_confirm_build");
emit("ai_lod_build_confirmation", { hero: "npc_dota_hero_axe", basic: "a,b,c", ultimate: "u1,u2", locked: true });
assert.equal(panels.BuildConfirmBtn.enabled, false);
emit("ai_lod_build_confirmation", { hero: "npc_dota_hero_axe", basic: "a,b,c", ultimate: "u1,u2", error: "unknown_runtime_reason" });
assert.equal(panels.BuildError.text, "invalid build", "Unknown validation errors use the localized invalid-build fallback");
state("STRATEGY_TIME");
vm.runInContext("selectedHero = ''; selectedBasics = []; selectedUltimates = [];", context);
const strategySnapshot = { phase: "STRATEGY_TIME", time: 15, players: [{ player_id: 0, team: 2, hero: "npc_dota_hero_axe", basic: "a,b,c", ultimate: "u1,u2", lane: "top", starting_gold: 600, gold: 350 }] };
emit("ai_lod_preparation", strategySnapshot);
assert.ok(shown("Preparation"));
assert.ok(!shown("DraftBackdrop"), "Strategy must leave normal shop and minimap exposed");
assert.ok(!shown("ChosenBuild"), "Bottom draft strip must not cover the normal HUD");
assert.equal(panels.StrategyBuild.FindChildrenWithClassTraverse("BuildSlot").length, 5);
assert.equal(panels.StrategyBuild.FindChildrenWithClassTraverse("BuildSlot")[4].children[0].abilityname, "u2",
	"Preparation snapshot restores the actual bonus ultimate without prior client draft memory");
assert.equal(panels.StrategyLanes.visible, true);
assert.equal(panels.StrategyGold.visible, true);
assert.ok(panels.StrategyGold.text.includes("600"));
assert.ok(panels.StrategyGold.text.includes("350"));
assert.ok(panels.LaneTop.BHasClass("Selected"));
click(panels.LaneMid);
assert.equal(sent.at(-1).name, "ai_lod_strategy_lane");
assert.equal(sent.at(-1).data.lane, "mid");
assert.ok(panels.LaneTop.BHasClass("Selected"), "Lane changes are not applied optimistically");
assert.ok(!panels.LaneMid.BHasClass("Selected"));
emit("ai_lod_preparation", { ...strategySnapshot, players: [{ ...strategySnapshot.players[0], lane: "mid" }] });
assert.ok(panels.LaneMid.BHasClass("Selected"), "Server snapshot acknowledges assigned lane");
assert.ok(panels.IntroductionPlayers.FindChildrenWithClassTraverse("RosterStatus")[0].text.includes("lane mid"));
state("INTRODUCTION");
emit("ai_lod_preparation", { ...strategySnapshot, phase: "INTRODUCTION", time: 5 });
assert.equal(panels.StrategyLanes.visible, false, "Lane assignment is strategy-only");
state("GAME");
emit("ai_lod_preparation", { phase: "STRATEGY_TIME" });
assert.ok(!shown("Preparation"));
const death = { draft_id: 10, selected_slot: "a", basic_slots: "a,b,c", ultimate_slots: "u1,u2",
	pending_basic: "a,b,c", pending_ultimate: "u1,u2", basic_offers: "d,e", ultimate_offers: "u3", rerolls: 3, time: 20 };
emit("ai_lod_death_draft", death);
assert.ok(shown("DeathDraft"));
assert.ok(!shown("DraftBackdrop"));
assert.equal(panels.DeathConfirmBtn.enabled, false, "Replace requires a staged change");
assert.equal(panels.DeathUltimateOffers.visible, false, "Basic slot must only expose basic offers");
click(panels.DeathBasicOffers.children[0]);
assert.equal(sent.at(-1).name, "ai_lod_death_ability");
assert.equal(sent.at(-1).data.draft_id, 10);
emit("ai_lod_death_draft", { ...death, pending_basic: "d,e,c", pending_ultimate: "u3,u2", rerolls: 0 });
assert.equal(panels.DeathConfirmBtn.enabled, true, "Multiple staged changes remain confirmable");
assert.equal(panels.DeathRerollBtn.enabled, false);
click(panels.DeathConfirmBtn);
assert.equal(sent.at(-1).name, "ai_lod_death_confirm");
emit("ai_lod_death_draft", { ...death, pending_basic: "d,b,c", loading: true });
assert.equal(panels.DeathLoading.visible, true);
assert.equal(panels.DeathRerollBtn.enabled, false);
assert.equal(panels.DeathKeepSlotBtn.enabled, false);
assert.equal(panels.DeathConfirmBtn.enabled, false);
assert.ok(panels.DeathBasicSlots.children.concat(panels.DeathUltimateSlots.children,
	panels.DeathBasicOffers.children, panels.DeathUltimateOffers.children).every(button => !button.enabled),
	"Resource loading disables every editable slot and replacement offer");
click(panels.DeathSkipBtn);
assert.equal(sent.at(-1).name, "ai_lod_death_skip", "Skip remains available during asynchronous resource loading");
assert.equal(sent.at(-1).data.draft_id, 10);
emit("ai_lod_death_draft", { ...death, basic_offers: "", ultimate_offers: "" });
assert.equal(panels.DeathLoading.visible, false);
assert.equal(panels.DeathEmpty.visible, true);
click(panels.DeathSkipBtn);
assert.equal(sent.at(-1).name, "ai_lod_death_skip");
emit("ai_lod_death_end", { draft_id: 10, skipped: true, cancelled: true });
assert.ok(!shown("DeathDraft"));
assert.ok(shown("DeathrollNotice"), "Explicit Skip should acknowledge that the original build was kept");
assert.equal(panels.DeathrollText.text, "loadout kept");
emit("ai_lod_death_draft", death);
emit("ai_lod_death_end", { draft_id: 9 });
assert.ok(shown("DeathDraft"), "Stale death end must not close a newer draft");
emit("ai_lod_death_timer", { draft_id: 10, time: 0 });
assert.ok(!shown("DeathDraft"));
state("GAME_END");
emit("ai_lod_death_draft", death);
assert.ok(!shown("DeathDraft"));
emit("ai_lod_results", { winner: 2, mvp: 0, runner_up: -1, players: [{ player_id: 0, team: 2, rank: 1 }] });
assert.ok(shown("MatchResults"));
click(panels.ResultsCloseBtn);
emit("ai_lod_results", { winner: 2, players: [] });
assert.ok(!shown("MatchResults"), "Repeated results snapshot must respect Close");
console.log("Panorama snapshot regressions passed.");
