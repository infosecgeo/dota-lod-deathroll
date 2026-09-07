# Offline tools

Python balance / compatibility simulators will live here (Phase 13+).

They must **never** run inside a live Dota match. Pipeline:

```
tools/ (analyze builds) → scripts/config/*.kv → VScript reads KV in-game
```
