# ConLogsApp

Client-side apps for the **ConLogs** logging platform (the web app lives in the separate
`ConLogs` repo — currently `epoglogs`). Data uploads to epoglogs.com for now.

## Contents

- **`ConLogs-Epoch/`** — the in-game addon for **Project Epoch** (WoW 3.3.5). Mesh gear/talent
  inspector (formerly *EpogArmory*), plus the in-progress live-logging work. Future sibling
  clients (e.g. `ConLogs-CoA/`) would live alongside it.
- **`companion/`** — the desktop companion app (Go, pure stdlib). Tails `WoWCombatLog.txt`,
  live-streams it to the site, and auto-uploads the addon's gear SavedVariables on session end.

## Notes

- The addon was renamed EpogArmory → **ConLogs-Epoch**. Its mesh addon-message prefix is
  intentionally kept as `"EpogArmory"` so renamed clients still sync with any peer still on the
  old addon during the transition.
- SavedVariables globals are now `ConLogsDB` / `ConLogsItemCacheDB` / `ConLogsTalentTreeDB`
  (the website ingest accepts the legacy `EpogArmory*` names too).
- `ConLogsSpike.lua` is a temporary debug diagnostic (`/conlogs spike …`) for Phase-2
  feasibility — not for release; remove before a public build.
