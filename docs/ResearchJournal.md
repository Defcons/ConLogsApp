# Research Journal — ConLogsApp

<!--
  The append-only chronological history: how the ConLogs addon platform got built,
  what was learned, which approaches were tried and dropped. The HISTORY of the
  triad — CodeMap = the machine · KnowledgeBase = the model · ResearchJournal =
  the history. Append; never rewrite old entries. When an iteration confirms a
  durable fact, promote the distilled statement to KnowledgeBase.md and cross-link.
  Seeded 2026-08-03 from `git log --reverse` (103 commits, 2026-06-02 → 2026-08-03).
-->

_Last verified: 2026-08-03 @ cb5004d — seeded from the full git history — by Claude Opus 4.8._

_The triad: **[CodeMap](../CodeMap.md) = the machine · [KnowledgeBase](KnowledgeBase.md)
= the model · ResearchJournal = the history.**_

## What this is / mission

Build two client-side WoW 3.3.5 Lua addons that embed everything a logging site
needs (gear/talents/buffs/positions/loot/difficulty) INTO the uploaded combat log,
so no companion app or server-side memory reading is needed. Project Epoch first
(`ConLogs-Epoch`, formerly EpogArmory); CoA (`ConLogs-CoA`) forked later. No build
step, hand-cut GitHub releases.

## The founding decision (2026-06-02, the first day)

- `63fe2d3` — **EpogArmory rebranded to ConLogs-Epoch v2.0.0**, joining the ConLogs
  platform. (The EpogArmory history predates this repo; v2.0.0 is the first ConLogs
  commit, so the numbering starts at 2.x.)
- `3cc00a2` → `ccc791f` — **a Go desktop companion app was added and DROPPED the
  same day.** THE architectural fork of the project: server-side memory reading
  isn't allowed and an addon can't upload, so the addon must make the combat log
  self-contained instead. Everything downstream follows from this. → KB §1.

## Epoch relay era (2026-06, v2.0 → v2.1)

- `d0d9774` — **the relay transport is invented**: gear/talents → combat log via
  `SPELL_CAST_FAILED`, base64 + chunking, landed-evidence gating on CLEU arg 12.
  Default OFF, `/conlogs relay on|off|test|status`. This is the mechanism the whole
  platform rides. → KB §2.
- `77e3e1f`, `e1772bb`, `179518b`, `a205196`, `2da787a`, `9a812dd` — **position
  telemetry + map identity + a standalone replay-viewer prototype** (`tools/`): MPQ
  map extractor (BLP2/DXT1 decode + stitch), relay decoder (`track.js`), per-map
  INSET calibration (patch-override priority so reskinned maps extract right), TDZ
  crash fix. The replay viewer is still a prototype — TS chunks land but nothing
  consumes them in production (KB §8 OPEN).
- `09f40a5` — spike `/conlogs spike unitpos`: probe whether PE exposes ANY API for
  OTHER units' positions. **Answer: no `UnitPosition` on PE** → forced the
  mesh-of-self design. → KB §3.
- `d7c0d69` — one-time import of the legacy `EpogArmoryDB` on login (merge
  players/caches/config per-guid when the old addon is still installed).
- `de4e5a8` — **relay flips to default ON**: every user's `/combatlog` auto-embeds
  gear/talents; opt-out via `/conlogs relay off`. Position telemetry stays opt-in
  (only useful in BGs on PE).
- `f610a2b` — rebrand all user-facing text `/epogarmory` → `/conlogs` (keeping the
  slash aliases + the wire `PREFIX="EpogArmory"` literal + the DB-import path).
- `193b533` — **ConLogs-Epoch v2.1.0**, the first tagged ConLogs release.
- `705ebe2` — v2.1.1: send each player's gear **once per version** (first seen /
  scanTime bump) instead of re-broadcasting the whole group every 2 min — cuts
  combat-log bloat.

## Capture-completeness + hardening (2026-06, v2.1.x)

- `4da1a9c`, `58c4f76`, `be7a5c3` — **buff capture**: snapshot pre-pull buffs
  (self+pet) because PE fires no pre-pull `SPELL_AURA_APPLIED`; extend to the whole
  group; add **periodic 3s aura polling** for log-invisible buffs (jujus, totems),
  dedup-on-change. → KB §3.
- `8a0e657`, `730d2a6` — reframe positions as a **mesh-of-self for instance replay**
  (map-gated). → KB §3.
- `ca5272e` — **land-gated dedup + pending/queue desync fix on eviction** — the
  correctness invariant: baselines advance only on confirmed land, never at enqueue.
  → KB §2.
- `c760271` — **taint hardening**: restore `SPELL_FAILED_*` to PRISTINE defaults on
  every teardown. → KB §2.
- `8e8c8ad` — **prune SavedVariables + harden the mesh** against crafted messages
  (bound `total`/`idx`, cap reassembly buffers, cooldowns key on authenticated
  sender). → KB §4, §5.
- `e1aeffb`, `181dd61`, `fcf323d`, `5847ede` — jitter position pulses to desync
  raid-wide; cache the guild-roster set; debounce browser search; minimap logging
  status.

## Epoch feature arc (2026-06 → 2026-07, v2.1.2 → v3.0.1)

- `2175746` + `e3b8db8` + `f66aa4c` — **loot capture (LT chunk)** for the site Loot
  tab; land loot looted out of combat incl. the final boss; de-spam repeated
  `CHAT_MSG_LOOT`.
- `ecda5b3`/`d0d3da8`, `000834a`, `9a9b216` — dungeon roster fixes: Strat mob/boss
  names lockstepped to Epoch destNames; **Baradin Hold detected via
  `GetRealZoneText` fallback** (PE returns parent "Tol Barad"); Tol Barad treated
  as an instance. → CodeMap `<instance-detection>`.
- `48cf4bd` — **version relay (VR chunk)**, once per session (v2.3.0).
- `64e23b8` — **runtime version becomes a Lua constant** so the tooltip tracks
  `/reload` (`GetAddOnMetadata` is stale until client restart). → KB §4.
- `1478753` — capture race + unbuffed base stats (v2.5.0).
- `8fe3e50` — BU buff/totem relay overhaul + raid FPS fixes (v2.5.1).
- `0284f1c` — **deterministic pet→owner relay (PO chunk)** (v2.6.0).
- `cda32bf` + `134b390` — **end-of-raid loot-flush button** + raid last-boss rosters
  for the end-of-raid loot prompt; per-fight FPS stutter fix (v2.7.0). (The flush
  button mitigates but does not fully cure the relay-rides-failed-casts limit — KB
  §8 OPEN.)
- `b681d21` — raid/dungeon FPS audit + relay throughput (v2.8.0).
- `cd4e6c7` + `1d64603` — capture Epoch's custom "Acuity" tooltip stat, then rename
  the key to "Alacrity" (v2.9.0 → v2.9.1).
- `b233cb1`, `ab79f3a`, `69b1e37` — scroll buffs in the BU snapshot; relay
  whole-raid + pet consumables via BU; per-GUID consumable scan throttle (v2.9.4).
- `30a23ae` — **ConLogs-Epoch v3.0.0**, raid FPS hardening. `b6518ba` — strip
  dev/extraction tooling from the public repo.

## CoA fork (2026-06 late → 2026-07, v0.2.0 → v0.3.7)

- `bca7f63` — **scaffold ConLogs-CoA** as a rebrand-only sibling of Epoch + a CoA
  probe. `2d4ef3a` — drop the Reality-Recalibrators gate + the level-60 requirement.
- `6b45f91`, `a4b4a00`, `803d81b`, `965aac8` — enumerate CoA's backported M+ API;
  **capture + relay difficulty (DI chunk)**; only relay affixes when a keystone is
  active; DI uses `GetActiveKeystoneInfo` + carries mapAreaID + dungeonID. → KB §6.
- `ad75b23` — **relax `CheckFullSet` to 5 slots** — Epoch's 16-slot/ilvl-55 gate
  blocked ALL storage on CoA leveling gear (the empty-gear-relay bug). → KB §6.
- `bc113e2` + `161e8ad` — auto-log ANY instance, stop on leaving instance/group
  (`ConLogsAutoLog.lua`); remove the Epoch dungeon tracker + training-dummy;
  DI carries difficultyName (v0.2.1).
- `b988555` — **read CoA talents via `C_CharacterAdvancement`** (fixes the `{0,0,0}`
  legacy read). `b24e035` — read SELF talents via `GetInspectedBuild` (fixes
  Wildwalker/custom classes). → KB §6.
- `9f52572` — **fix the addon failing to load: the 200-file-scope-local chunk
  limit** (v0.2.6). The bite that proved KB §4's Lua-5.1 cap — module helpers must
  live on a table.
- `f5b1836` → `693920c` → `0f00f20` — `/conlogs dumpentries` exports the CoA node DB
  for the site decoder; store under an EXISTING SV so it persists (a NEW top-level
  SV won't register without a full restart); unified `L:` selection format.
- `aab7aa7` + `0025bbb` + `fef0f43` — node-map completeness: sweep
  `GetTalentsByClass`, resolve ability nodes via `GetEntryByInternalID`, then switch
  to `GetEntriesByClass` for the FULL talents+abilities set.
- `a9f00ba` + `786ad42` — `tools/` CoA talent-tree data contract + SV extractor
  (`extract_coa_talent_tree.py` → `coa_talent_tree.json`); document tree edges
  (`ConnectedNodes`) + choice groups.
- `e3a2b35` → `ac64e57` → `dc8d992` → `c0cc422` → `d107cc0` — **in-game CoA talent
  tree** rendered in the Talents panel: positioned node-graph, full node set, spec
  background shared across tabs (so the Class tree shows), authentic node shapes
  (circle/square/hex) (v0.2.9 → v0.3.4). Constraint learned: no `frame:CreateLine`
  on this client → axis-aligned L-connector edges. → KB §6.
- `43710f4` + `ab91155` — `dumpentries` exports spell descriptions because
  `entry.Description` is EMPTY on CoA (resolve via `GetSpellDescription`) (v0.3.5).
- `fd69a63` + `f959bf7` — **wire field 47: per-slot scaled item stats** on the
  character scan (v0.3.7); relay spec added. Fixes CoA level-scaling making the
  global itemID cache last-scan-wins. → KB §6, `COA-SCALED-ITEM-STATS-RELAY-SPEC.md`.

## Documentation (2026-07 → 2026-08)

- `3b4b0cb` — **CODE-MAP.md seeded** (durable facts migrated from cross-project
  notes). `2cec5a3`, `a174a0f`, `4d86551` — CODE-MAP kept current (CoA talent
  capture/map, chunk-local-limit, the release "Latest" trap correction, field 47).
- `a749537`, `a7096ee` — wow tree relocated to `C:\Dev\games\wow`; extractor writes
  its json relative to the script (no absolute path).
- `d318865` — **`build_release.py`**: strip dev slash commands from public builds.
  → KB §7.
- `cb5004d` (HEAD) — **rename CODE-MAP.md → CodeMap.md**, normalize the stamp.
- **2026-08-03** — this KnowledgeBase + ResearchJournal seeded (deep triad pass).

## Milestones

| Date | Milestone |
|---|---|
| 2026-06-02 | Rebrand to ConLogs-Epoch v2.0.0; companion app added + dropped same day |
| 2026-06-02 | Relay transport invented (SPELL_CAST_FAILED, arg 12) |
| 2026-06 | v2.1.0 first ConLogs release; relay default ON; buff/position capture |
| 2026-06→07 | Epoch feature arc: loot/version/PO chunks, FPS hardening → v3.0.0/3.0.1 |
| 2026-06 late | ConLogs-CoA fork scaffolded (v0.2.0) |
| 2026-07 | CoA talent capture (C_CharacterAdvancement), auto-log, DI difficulty |
| 2026-07 | CoA in-game talent tree rendered (v0.2.9 → v0.3.4) |
| 2026-07-09 | CoA v0.3.7 — per-slot scaled item stats (field 47) |
| 2026-08-03 | Triad completed (CodeMap + KnowledgeBase + ResearchJournal) |

## Open questions / backlog

- End-of-raid relay flush (the real fix for post-final-kill loot) — KB §8.
- Server-side position replay viewer (TS chunks land but aren't consumed) — KB §8.
- CoA talent rendering on coalogs.com — addon side done, site side pending — KB §8.
- Live-keystone DI probe inside an active M+ — KB §9.
- Resolve the GPLv3-vs-MIT license line in `ConLogs-Epoch/README.md` — KB §8.
