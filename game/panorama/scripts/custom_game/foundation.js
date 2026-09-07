// foundation.js — state badge. Does not block input.
"use strict";

var badge = $("#StateBadge");
var label = $("#StateLabel");

function SetStateText(name) {
	if (label) {
		label.text = "AI-LOD · " + (name || "WAITING");
	}
}

GameEvents.Subscribe("ai_lod_state", function (event) {
	SetStateText(event.name);
	if (badge && event.name === "PLAYING") {
		badge.AddClass("Hidden");
	} else if (badge) {
		badge.RemoveClass("Hidden");
	}
});

GameEvents.Subscribe("ai_lod_playing", function () {
	SetStateText("PLAYING");
	if (badge) badge.AddClass("Hidden");
});

SetStateText("WAITING");
