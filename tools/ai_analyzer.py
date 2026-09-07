#!/usr/bin/env python3
"""
Phase 14 — Offline AI-style ability analyzer for AI-LOD.

Heuristic combo analysis (no live match calls):
- flags multi-disable / multi-mobility / multi-save stacks
- ranks high synergy / high risk kits
- emits tools/ai_analysis_report.json
"""
from __future__ import annotations

import argparse
import json
import random
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "tools" / "hero_ability_db.json"
OUT_JSON = ROOT / "tools" / "ai_analysis_report.json"

RISKY_TAGS = {"disable", "control", "clone", "global", "steal", "bkb", "save"}
MOBILITY = {"mobility"}
SAVE = {"save", "survival", "heal"}


def load_db() -> dict:
    with DB_PATH.open() as f:
        return json.load(f)


def kit_tags(abilities: dict, kit: list[str]) -> Counter:
    c = Counter()
    for a in kit:
        c[abilities.get(a, {}).get("category", "unknown")] += 1
    return c


def risk_score(tags: Counter) -> int:
    score = 0
    for t, n in tags.items():
        if t in RISKY_TAGS:
            score += n * 3
        if t in MOBILITY:
            score += n * 2
        if t in SAVE:
            score += n * 2
    # Multi-disable is especially spicy
    score += max(0, tags.get("disable", 0) - 1) * 4
    score += max(0, tags.get("control", 0) - 1) * 4
    return score


def analyze(db: dict, samples: int = 800) -> dict:
    abilities = db["abilities"]
    blacklist = set(db.get("blacklist") or [])
    regular = [a for a, m in abilities.items() if m.get("type") != "ultimate" and a not in blacklist]
    ultimate = [a for a, m in abilities.items() if m.get("type") == "ultimate" and a not in blacklist]

    kits = []
    for _ in range(samples):
        kit = random.sample(regular, min(4, len(regular))) + random.sample(ultimate, min(2, len(ultimate)))
        tags = kit_tags(abilities, kit)
        power = sum(int(abilities[a].get("power_score", 0)) for a in kit)
        risk = risk_score(tags)
        kits.append({
            "kit": kit,
            "power": power,
            "risk": risk,
            "tags": dict(tags),
            "flags": {
                "multi_disable": tags.get("disable", 0) + tags.get("control", 0) >= 3,
                "multi_mobility": tags.get("mobility", 0) >= 2,
                "save_stack": tags.get("save", 0) + tags.get("survival", 0) >= 2,
            },
        })

    high_risk = sorted(kits, key=lambda k: (-k["risk"], -k["power"]))[:15]
    high_power = sorted(kits, key=lambda k: (-k["power"], -k["risk"]))[:15]
    flagged = [k for k in kits if any(k["flags"].values())]

    # Category coverage across the whole DB
    cat_all = Counter(m.get("category", "unknown") for m in abilities.values())

    return {
        "samples": samples,
        "flagged_pct": round(100.0 * len(flagged) / samples, 2),
        "high_risk_kits": high_risk,
        "high_power_kits": high_power,
        "category_coverage": dict(cat_all.most_common()),
        "recommendations": [
            "Keep MaxBudget near simulated average + 1σ to curb stacked disables.",
            "Blacklist intrinsic/transform ultimates (already seeded in blacklist.kv).",
            "Death draft should prefer mid power_score basics to avoid snowball.",
            "Prefer offering mixed categories in ability draft sample windows.",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="AI-LOD offline analyzer")
    parser.add_argument("--samples", type=int, default=800)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    random.seed(args.seed)

    report = analyze(load_db(), samples=args.samples)
    OUT_JSON.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({
        "samples": report["samples"],
        "flagged_pct": report["flagged_pct"],
        "top_risk": report["high_risk_kits"][0] if report["high_risk_kits"] else None,
        "recommendations": report["recommendations"],
    }, indent=2))
    print(f"Wrote {OUT_JSON}")


if __name__ == "__main__":
    main()
