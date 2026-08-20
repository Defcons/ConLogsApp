# OrientationMap — ConLogsApp

<!--
  The INJECTED map hub — a SessionStart hook injects this file WHOLE. Rules: ~/.claude/CLAUDE.md §5.
    - BOUNDED, hub-only: what-this-is, subsystem index, GLOBAL landmines. Per-file symbols +
      domain-local gotchas live in NavigationMap.md — read a domain's section there FIRST.
    - New map knowledge lands in NavigationMap BY DEFAULT; promote here only what bites from
      UNRELATED work, or a domain's headline row.
    - Anchor to SYMBOLS, never line numbers. Update in the SAME COMMIT; bump the stamp.
-->

_Last verified: 2026-08-20 @ 4a58032 — split at the ~20 KB ceiling: per-file symbols + domain-local gotchas moved to NavigationMap.md; pointers re-verified against code (Epoch 3.0.1 / CoA 0.3.7)._

## What this is

Client-side apps for the **ConLogs** logging platform (formerly *EpogArmory* / *epoglogs*). The web
app lives in a separate `ConLogs`/`epoglogs` repo; data currently uploads to epoglogs.com. This repo
holds two WoW 3.3.5 **Lua addons** (no build step, no bundler) plus offline decode/build `tools/`.

**Durable design decision:** the model is **addon-relay + manual single-file upload — NO companion
executable, NO server-side memory reading.** A Go desktop companion was prototyped for live
streaming, then **dropped** (commit ccc791f): the relay makes `WoWCombatLog.txt` self-contained, and
an addon can't upload anyway. Positions/gear/etc. must come from an in-game addon because reading
game memory server-side is not permitted. (Release versions/status are intentionally kept OUT of
this map — see the repo's GitHub Releases + `.toc ## Version`.)

## The repo bible (six docs — §5)

- **`OrientationMap.md`** (this) = injected hub: shape, subsystem index, global landmines.
- **`NavigationMap.md`** = per-domain detail: file/symbol pointers, local gotchas, contracts.
- **`docs/KnowledgeBase.md`** = the MODEL: tier-tagged behaviour truth (wire protocol, capture
  mechanics, platform limits, release model).
- **`docs/ResearchJournal.md`** = append-only history · **`docs/ToDo.md`** = deferral ledger ·
  **`docs/Testing.md`** = pending-manual-test queue.

## Layout & conventions

- **`ConLogs-Epoch/`** — the addon for **Project Epoch** (formerly EpogArmory). Mesh gear/talent
  inspector + combat-log relay. Loaded from `…/resources/epoch_live/Interface/AddOns/`. User-facing
  docs/screenshots: `ConLogs-Epoch/docs/`.
- **`ConLogs-CoA/`** — sibling fork for **Conquest of Azeroth** (CoA, an Ascension client mode):
  rebrand of Epoch + M+ difficulty capture + CoA talents. Loaded from the SHARED
  `…/resources/client/Interface/AddOns/` (NOT `ascension_ptr/…`) — Nav §CoA fork.
- **`tools/`** — offline helpers. Tracked: `build_release.py`, `extract_coa_talent_tree.py`,
  `COA_TALENTS_CONTRACT.md`. `coa_talent_tree.json` is generated + gitignored. Untracked local dev
  files (replay decoder `track.js`, map PNGs) are kept out of the public repo by design — Nav
  §Tools & release.
- Load order is set by each addon's `.toc`. Epoch: `ConLogs.lua` → `ConLogsUI.lua` →
  `ConLogsDummy.lua` → `ConLogsDungeon.lua` → `ConLogsRelay.lua` → `ConLogsSpike.lua`. CoA drops
  Dummy/Dungeon, adds `ConLogsAutoLog.lua`.

## Subsystem index

- **Core / mesh / storage** — addon-message mesh (scan → broadcast gear/talents → `ConLogsDB`),
  SV pruning, mesh hardening, version ping. Entry: `ConLogs.lua` (both addons; `PREFIX`,
  `CheckFullSet`, `PruneStoredData`). → Nav §Core / mesh / storage
- **Relay transport** — the SPELL_CAST_FAILED relay: everything the site needs rides base64 chunks
  into the combat log; land-gated dedup; PE capture mechanics (buffs/positions). Entry:
  `ConLogsRelay.lua` (`PREFIX_FAMILY`, `enqueue*`). → Nav §Relay transport
- **Browser / inspect UI** — paperdoll browser, per-spec gear sets, minimap shield. Entry:
  `ConLogsUI.lua`. → Nav §Browser / inspect UI
- **Epoch-only modules** — training-dummy DPS parse + dungeon/raid tracker (auto-`/combatlog`,
  loot reminder). Entry: `ConLogsDummy.lua`, `ConLogsDungeon.lua` (`DUNGEONS`). → Nav §Epoch-only
  modules
- **CoA fork** — live folder, auto-logging, DI difficulty capture, relaxed full-set gate,
  `C_CharacterAdvancement` talent capture/export + in-game tree. Entry: `ConLogs-CoA/*`
  (`CoaBuild`, `enqueueDifficulty`, `RenderCoA`). → Nav §CoA fork
- **Dev spike** — `/conlogs spike …` diagnostics; stripped from release zips. Entry:
  `ConLogsSpike.lua`. → Nav §Dev spike
- **Tools & release** — hand-built zips via `build_release.py` (whitelist + dev-strip), the
  two-game "Latest" trap, offline extractors. **Release = bump BOTH `.toc ## Version` AND the Lua
  `ADDON_VERSION`.** → Nav §Tools & release

## Global landmines

- **<mesh-prefix-literal>**: the mesh addon-message `PREFIX` is kept the literal string
  `"EpogArmory"` in BOTH addons (`ConLogs.lua`) so renamed/CoA clients still sync with any legacy
  EpogArmory peer. **DO NOT change it.** The position mesh uses a SEPARATE
  `POS_PREFIX = "ConLogsPos"` so positions never hit the gear-reassembly path.
- **<chunk-local-limit>**: `ConLogs.lua`'s main chunk sits right at Lua 5.1's
  **200-file-scope-local cap**. Adding bare module-level `local`s can push it over → the file
  silently fails to COMPILE and the whole addon never loads (`/conlogs` → "unknown command", no SV
  write — looks like the addon vanished). Put new module-level helpers on a TABLE (e.g.
  `CoaBuild.*`), not bare `local function`. Verify after edits with `luaparser` (count
  `LocalFunction`+`LocalAssign` targets directly under the main chunk; must stay ≤200). No lua
  binary here — `pip install luaparser`.
- **<sv-size>**: 3.3.5 silently drops a WHOLE SavedVariable that exceeds an internal size limit —
  any feature adding persistent data must respect `PruneStoredData` (params: Nav §Core
  `<sv-prune>`).
- **<ps-path-guards>**: in this workspace `Remove-Item -Recurse` on staging/AddOns paths and
  `Select-String` get BLOCKED (sometimes silently, exit 1). Use whitelist `Copy-Item -Force` and
  the Grep/Read tools (not Select-String/Get-Content). `zip` is NOT in the git-bash here → build
  with `python -c "import shutil; shutil.make_archive(...)"`. Also clean-sync source into the live
  AddOns folder on every change.

## Surfaces & cross-repo contract

- User surface: `/conlogs` slash root (+ `/epogarmory` alias); minimap shield; CoA Talents panel.
- The addon emits `[[CL_<KIND>_v1_…]]<b64>` chunks; the epoglogs web-app repo (`js/conlogs-relay.js`,
  `lib/conlogs-wire-parser.js`) reassembles + decodes. Wire details + the 1-based/0-based talent
  trap: Nav §Relay transport; behaviour truth: KB §2/§5.
- Distribution: GitHub Releases on this repo — Epoch tags `v*`, CoA tags `coa-v*`; the shared
  "Latest" flag trap + workaround: Nav §Tools & release `<coa-latest-trap>`.

## Deferred

See `docs/ToDo.md` (deferral ledger, incl. the license-line inconsistency) + `docs/Testing.md`
(pending human verification).
