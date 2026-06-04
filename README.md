# ConLogsApp

Client-side apps for the **ConLogs** logging platform (the web app lives in the separate
`ConLogs` repo — currently `epoglogs`). Data uploads to epoglogs.com for now.

## Contents

- **`ConLogs-Epoch/`** — the in-game addon for **Project Epoch** (WoW 3.3.5). Mesh gear/talent
  inspector (formerly *EpogArmory*). Embeds gear/talents/positions into the combat log via the
  `SPELL_CAST_FAILED` relay, so a single uploaded `WoWCombatLog.txt` carries everything. Future
  sibling clients (e.g. `ConLogs-CoA/`) would live alongside it.

> A desktop companion executable was prototyped and **dropped** — the relay makes the combat log
> self-contained, so manual single-file upload on the website is enough; no external app needed.

## Notes

- The addon was renamed EpogArmory → **ConLogs-Epoch**. Its mesh addon-message prefix is
  intentionally kept as `"EpogArmory"` so renamed clients still sync with any peer still on the
  old addon during the transition.
- SavedVariables globals are now `ConLogsDB` / `ConLogsItemCacheDB` / `ConLogsTalentTreeDB`
  (the website ingest accepts the legacy `EpogArmory*` names too).
- `ConLogsSpike.lua` is a temporary debug diagnostic (`/conlogs spike …`) for Phase-2
  feasibility — not for release; remove before a public build.

## License

[GNU General Public License v3.0 or later](LICENSE) — Copyright © 2026 Defcon.

Copyleft: you are free to use, study, modify, and redistribute this code, but any distributed
derivative must also be released under the GPLv3 with source available.
