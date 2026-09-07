#!/usr/bin/env python3
"""
Phase 13 — Offline balance engine for AI-LOD.

Reads tools/hero_ability_db.json (and optionally scripts/config/*.kv),
scores ability kits, flags over-budget builds, and writes recommendations
into scripts/config/balance.kv notes. Never runs in-match.
"""
from __future__ import annotations

import argparse
import json
import random
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "tools" / "hero_ability_db.json"
BALANCE_KV = ROOT / "game" / "scripts" / "config" / "balance.kv"
OUT_JSON = ROOT / "tools" / "balance_report.json"


def load_db() -> dict:
    with DB_PATH.open() as f:
        return json.load(f)


def score_kit(abilities: dict, kit: list[str]) -> int:
    return sum(int(abilities.get(a, {}).get("power_score", 0)) for a in kit)


def sample_kits(db: dict, n: int = 500, basics: int = 4, ults: int = 2) -> list[dict]:
    abilities = db["abilities"]
    blacklist = set(db.get("blacklist") or [])
    regular = [a for a, m in abilities.items() if m.get("type") != "ultimate" and a not in blacklist]
    ultimate = [a for a, m in abilities.items() if m.get("type") == "ultimate" and a not in blacklist]
    results = []
    for _ in range(n):
        b = random.sample(regular, min(basics, len(regular)))
        u = random.sample(ultimate, min(ults, len(ultimate)))
        kit = b + u
        results.append({
            "kit": kit,
            "score": score_kit(abilities, kit),
            "categories": [abilities[a].get("category") for a in kit],
        })
    return results


def analyze(db: dict, max_budget: int = 28) -> dict:
    sims = sample_kits(db)
    scores = [s["score"] for s in sims]
    over = [s for s in sims if s["score"] > max_budget]
    cat_counts = Counter()
    for s in sims:
        cat_counts.update(s["categories"])
    return {
        "samples": len(sims),
        "max_budget": max_budget,
        "score_min": min(scores) if scores else 0,
        "score_max": max(scores) if scores else 0,
        "score_avg": round(sum(scores) / len(scores), 2) if scores else 0,
        "over_budget_pct": round(100.0 * len(over) / len(sims), 2) if sims else 0,
        "top_over_budget": sorted(over, key=lambda x: -x["score"])[:10],
        "category_frequency": dict(cat_counts.most_common(20)),
        "hero_counts": {k: len(v) for k, v in db.get("heroes", {}).items()},
        "ability_count": len(db.get("abilities", {})),
        "blacklist_count": len(db.get("blacklist", [])),
    }


def write_balance_kv(report: dict, max_budget: int) -> None:
    # Keep MaxBudget authoritative; stamp version + summary note.
    text = f'''"Settings"
{{
	"MaxBudget"		"{max_budget}"
	"Version"		"1.0"
	"BasicSlots"	"4"
	"UltimateSlots"	"2"
	"HeroOfferCount"	"4"
	"BanTime"		"50"
	"HeroDraftTime"	"45"
	"AbilityDraftTime"	"75"
	"UltimateDraftTime"	"40"
	"DeathDraftTime"	"25"
	"DeathRerolls"	"3"
	"SimAvgScore"	"{report.get("score_avg", 0)}"
	"SimOverBudgetPct"	"{report.get("over_budget_pct", 0)}"
}}

"Notes"
{{
	// Offline Python tools write recommendations here.
	// Live matches only read this file — they never call external AI.
	"GeneratedBy"	"tools/balance_engine.py"
	"AbilityCount"	"{report.get("ability_count", 0)}"
	"HeroCount"	"{sum(report.get("hero_counts", {}).values())}"
}}
'''
    BALANCE_KV.write_text(text)


def main() -> None:
    parser = argparse.ArgumentParser(description="AI-LOD offline balance engine")
    parser.add_argument("--budget", type=int, default=28)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    random.seed(args.seed)

    db = load_db()
    report = analyze(db, max_budget=args.budget)
    OUT_JSON.write_text(json.dumps(report, indent=2) + "\n")
    write_balance_kv(report, args.budget)
    print(json.dumps({k: report[k] for k in (
        "samples", "max_budget", "score_min", "score_max", "score_avg",
        "over_budget_pct", "ability_count", "blacklist_count", "hero_counts"
    )}, indent=2))
    print(f"Wrote {OUT_JSON}")
    print(f"Updated {BALANCE_KV}")


if __name__ == "__main__":
    main()
