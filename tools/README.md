# Offline tools (Phases 13–14)

Python balance / compatibility analyzers live here. They **never** run inside a live Dota match.

```
tools/ (analyze builds) → scripts/config/*.kv → VScript reads KV in-game
```

## Data

- `hero_ability_db.json` — generated full hero/ability roster used by both tools and as source of truth for KV regeneration.

## Commands

```bash
# Score random kits, update balance.kv Sim* fields
python3 tools/balance_engine.py --budget 28

# Heuristic combo / risk analysis
python3 tools/ai_analyzer.py --samples 800
```

Outputs:

- `tools/balance_report.json`
- `tools/ai_analysis_report.json`
- updates `game/scripts/config/balance.kv`
