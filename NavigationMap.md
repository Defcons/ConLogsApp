# NavigationMap — ConLogsApp

<!--
  The on-demand map layer — NOT injected; read per-domain. Rules: ~/.claude/CLAUDE.md §5.
    - ONE section per domain, mirroring OrientationMap's subsystem index (its rows point here).
      Entering a domain = read its section FIRST.
    - Per-file symbol pointers, domain-LOCAL gotchas, intra-domain contracts. New map knowledge
      lands HERE by default; promote to the hub only what bites from UNRELATED work.
    - Anchor to SYMBOLS, never line numbers. Behaviour facts/numbers → docs/KnowledgeBase.md;
      discovery narrative → docs/ResearchJournal.md. Update in the SAME COMMIT; bump the stamp.
-->

_Last verified: 2026-08-20 @ 4a58032 — created in the OrientationMap split (hub was at the ~20 KB ceiling); all file/symbol pointers spot-checked against code (Epoch 3.0.1 / CoA 0.3.7)._

## Core / mesh / storage

- **Core** → `ConLogs.lua` (~4000 lines, both addons) — addon-message mesh (scan groupmates →
  broadcast gear/talents → store in `ConLogsDB`), version ping, legacy `EpogArmoryDB` import.
  Key symbols: `PREFIX` (`"EpogArmory"` literal — hub `<mesh-prefix-literal>`), `ADDON_VERSION`
  (Lua constant — see §Tools & release `<version-display>`), `CheckFullSet`, `PruneStoredData`,
  `CompareMajorMinor`. Slash root: `SlashCmdList["CONLOGS"]` = `/conlogs` (+ `/epogarmory` alias).
- **gotcha — <sv-prune>** (detail for hub `<sv-size>`): `PruneStoredData()` runs at `PLAYER_LOGIN`:
  age-prune player records (>45d), count-cap 4000 (drop oldest), age-prune item cache (>60d),
  drop orphan `lastScanned`.
- **gotcha — <mesh-hardening>**: the reassembler bounds untrusted wire input (reject `total>64` /
  out-of-range `idx`, cap concurrent reassembly buffers at 200). Anti-abuse cooldowns key on the
  authenticated `CHAT_MSG_ADDON` `sender` (4th arg), NOT the spoofable wire `requester` field.
- **contract — mesh interop**: any client on `PREFIX="EpogArmory"` interoperates — ConLogs-Epoch,
  ConLogs-CoA, and legacy EpogArmory all share the reassembly path (CoA is a separate client so no
  name collision despite identical SV/PREFIX names).

## Relay transport

- **Relay** → `ConLogsRelay.lua` — the SPELL_CAST_FAILED relay. Key symbols: `PREFIX_FAMILY`
  (`"[[CL_"`), per-kind prefixes `CI/TS/BU/LT/VR/PO_PREFIX` (+ CoA `DI`), `FAILEDTYPE_ARG = 12`,
  `FAIL_GLOBALS`, `PRISTINE` (taint restore), `POS_PREFIX = "ConLogsPos"`,
  `enqueueGroupCI`/`enqueueBuffs`/`enqueueVersion`/`enqueuePetOwners`.
- **gotcha — <relay-transport>**: data rides the **SPELL_CAST_FAILED relay** — the addon overwrites
  the `SPELL_FAILED_*` global error strings with base64 chunks; the next *failed* cast makes the
  engine write that string as the CLEU `failedType` field (**arg index 12** on PE, ~1023 chars,
  ~950 usable after the ~60-char header). Chunk header
  `[[CL_<KIND>_v1_<session>_<id>_<seq>/<total>]]<b64>`. Kinds: `CI` gear/talents/stats, `BU`
  buff+totem auras, `TS` positions, `LT` loot, `VR` version, `PO` pet→owner (Epoch), `DI`
  difficulty (CoA). No LibDeflate on PE → no compression.
- **gotcha — <relay-rides-failed-casts>**: a chunk lands ONLY when a player fails a cast. **After
  the final boss kill nobody casts → nothing relays → end-of-raid loot never lands** (architectural
  limit, not a bug). A low-casting or immediately-logging-out player relays little. An end-of-raid
  flush is the open fix (docs/ToDo.md). (As of the out-of-combat change the relay also runs out of
  combat so post-kill loot can ride a *later* failed cast.)
- **gotcha — <land-gated-dedup>**: per-version/per-unit dedup baselines (`relayedVersion`,
  `relayedBuffs`) advance ONLY when a chunk is **confirmed landed** (via an `onLand` callback fired
  from `onFailed` when landed-evidence — a later failedType starting with `[[CL_` — is seen), NEVER
  at enqueue. Advancing at enqueue = silent permanent data loss if the chunk never lands. Also: on
  ring-cap front-eviction (`table.remove(queue,1)`) you MUST reset `pending=nil` or the next failed
  cast credits an innocent chunk as landed.
- **gotcha — <taint-pristine-restore>**: overwriting `SPELL_FAILED_*` taints the secure cast path
  (errors + UIErrorsFrame red text are suppressed). Capture the **PRISTINE** globals ONCE at file
  load (`PRISTINE = {}`, populated from `_G[g]` before any overwrite) and ALWAYS restore to those —
  never a value read at first-overwrite (could be a stale chunk string). Restore unconditionally on
  `PLAYER_LEAVING_WORLD` + `PLAYER_LOGOUT`. Same pattern in `ConLogsSpike.lua`.
- **gotcha — <pe-capture-gotchas>** (why captures work the way they do on the Project Epoch client):
  - Pre-pull buffs fire no `SPELL_AURA_APPLIED` → snapshot self+pet auras at each pull
    (`PLAYER_REGEN_DISABLED`).
  - **Jujus + totem buffs emit NO combat-log aura events at all** → periodic 3s aura poll relays a
    unit only when its aura-set CHANGES (dedup-on-change); server reconstructs windows from edges.
    `UnitAura(unit,i,"HELPFUL")` spellId is at return index 11 on 3.3.5.
  - **Positions**: `GetPlayerMapPosition` returns only *self* inside PvE instances (others = 0,0);
    PE has **no `UnitPosition`**. BGs expose everyone to one logger. → mesh-of-self: each client
    broadcasts its own pos over `ConLogsPos`, logger aggregates. `withCurrentZoneMap` does the
    `SetMapToCurrentZone` dance only when self reads 0,0 and the map is closed. **Map-validity
    guard**: relay nothing when `GetMapInfo()` is a continent/world name (Kalimdor/Azeroth/etc.) —
    e.g. Onyxia has no instance map and falls back to "Kalimdor".
- **contract — addon relay → epoglogs server**: the addon emits `[[CL_<KIND>_v1_…]]<b64>` chunks in
  the combat log; the server (`js/conlogs-relay.js` RelayReassembler + `lib/conlogs-wire-parser.js`
  `parseWirePayload`, in the SEPARATE web-app repo) reassembles and decodes. **Wire format trap**:
  the outer per-tab array is **1-based** (`[null, tab1, tab2, tab3]`); inner per-tab arrays are
  **0-based** — reading `ranks[talent.index]` 1-based drops the first talent and shifts the whole
  tree. Server-side data-coverage/decode gotchas (loot Epic+-only + cross-log dedup, totem-aura
  self-only propagation, talent 0-based) live in the **web app repo**, not here.

## Browser / inspect UI

- **UI** → `ConLogsUI.lua` — paperdoll browser, per-spec gear sets, minimap shield.
- The CoA-only in-game talent tree lives in `ConLogs-CoA/ConLogsUI.lua` — see §CoA fork
  `<coa-ingame-tree>`.

## Epoch-only modules

- **Dummy DPS parse** → `ConLogsDummy.lua` — training-dummy DPS test; owns `LoggingCombat`
  carefully (`dummyStartedLog` guard).
- **Dungeon/raid tracker** → `ConLogsDungeon.lua` — `DUNGEONS` roster table keyed by
  `GetInstanceInfo()` name; auto-`/combatlog`; loot reminder.
- **gotcha — <instance-detection>**: **Baradin Hold trap**: PE returns
  `GetInstanceInfo()="Tol Barad"` (parent) + `type="party"`; `DetectDungeon` falls back to
  `GetRealZoneText()` when the info name misses the roster. Diagnose with `/conlogs dungeondebug`.

## CoA fork (ConLogs-CoA/)

- **CoA removed vs Epoch**: dungeon-run tracker + training-dummy deleted (`ConLogsDungeon.lua` +
  `ConLogsDummy.lua` absent from the fork; `/conlogs dummy|dungeon|dungeondebug` gone).
- **Auto-logging** → `ConLogsAutoLog.lua` — replaces the Epoch dungeon module: auto-START
  `/combatlog` on entering ANY instance, auto-STOP on leaving instance/group; gated by
  `ConLogsDB.config.raidAutoLog` (`/conlogs raidlog`).
- **gotcha — <coa-live-folder>**: the CoA client loads addons from the SHARED
  `…/resources/client/Interface/AddOns`, NOT `ascension_ptr/…`. SV =
  `…/client/WTF/Account/<ACCT>/SavedVariables/ConLogs-CoA.lua`.
- **gotcha — <coa-difficulty>**: CoA backports a retail Mythic+ API. `ConLogs-CoA/ConLogsRelay.lua`
  `enqueueDifficulty` relays one land-gated, top-priority `[[CL_DI_` chunk per run (dedup on
  content) at each pull. Source getter `C_MythicPlus.GetActiveKeystoneInfo()` → `{keystoneLevel,
  dungeonID, rewardMultiplier, activeAffixes}` (0/empty outside a keystone). `GetCurrentAffixes()`
  is the WEEKLY pool (populates even on normal runs → only trust affixes when a keystone is
  active). All getters are pcall-guarded → degrade to `GetInstanceInfo` fields. Payload:
  `DI|<getTimeMs>|<unixSec>|<name>^<type>^<giDiff>^<maxPlayers>^<group>^<keyActive>^<keyLevel>^
  <affixCSV>^<mapAreaID>^<dungeonID>^<difficultyName>`. `GetMapFinalEncounter(mapID)` needs the
  keystone dungeon mapID (returns 0/{} for a world-area id), so the run goal is resolved
  server-side from static CoA data, not live. CoA marker: `GetRealmName()` contains "Conquest of
  Azeroth".
- **gotcha — <coa-fullset-relaxed>**: Epoch's `CheckFullSet` required 16 slots + avg ilvl ≥55,
  which blocked ALL storage on CoA (leveling gear). CoA relaxes to `COA_MIN_EQUIPPED_SLOTS = 5`,
  no ilvl floor.
- **gotcha — <coa-talents>** (talent CAPTURE, fixed — the old `{0,0,0}` legacy read is dead): CoA
  does NOT use `GetTalentInfo` (empty for CoA classes) nor DF `C_Traits` — it uses Ascension's
  custom **`C_CharacterAdvancement`**. `ConLogs.lua` `CoaBuild` table: `CoaBuild.Encode(unit)` →
  `"L:"+nodeId:rank,…` via `GetInspectedBuild(unit, spec)` (authoritative for ANY class incl.
  Wildwalker/Primalist; self is warmed by `CoaBuild.Warm`=`InspectUnit("player")` at
  login/PLAYER_TALENT_UPDATE/self-scan; iterate-`GetAllEntries` only as fallback). Wire **45=caSpec,
  46=caBuild** (append-only tail); stored `set.caSpec/caBuild`; rides the CI relay unchanged. **Wire
  47=per-slot scaled item stats** (`BuildScaledSlotStats` → `slot~itemID~itemLevel~TOKEN=val,…;…`,
  stored `set.slotStats`): CoA scales item stats to the wearer's level, and the itemID-keyed global
  hint cache (field 40) is last-scan-wins — 47 re-homes the SAME `GetItemStats(link)` values
  per-slot on the character's own scan so the site stores them per-character. Respec re-scan forced
  by clearing `lastSelfFingerprint` (the legacy fingerprint can't see CoA talent changes). Full
  external-API notes: ~/.claude memory `reference_coa_talent_api.md`.
- **gotcha — <coa-talent-map>**: `/conlogs dumpentries` exports the full node map to
  **`ConLogsTalentTreeDB.coaExport.nodes[]`** — written into that EXISTING SV on purpose (a NEW
  top-level SV won't register on this client without a full restart, so it never persisted). Node
  source = **`GetEntriesByClass(class,tab,false)`** (the FULL set incl. ABILITY nodes — what the
  in-game tree uses; `GetTalentsByClass` is talents-ONLY and silently drops abilities like
  Bearskin/Natural Efficiency) swept over all DBC class×spec combos, ∪ `GetAllEntries` ∪
  `GetEntryByInternalID` over every seen pick. Per node: id, name, icon(basename), nodeType, x/y
  (custom classes, integer grid 0–10 × 0–9) or col/row (default), **`connected[]` = THE tree edges**
  (from `entry.ConnectedNodes`; `parent`/`requires` are near-empty — NOT the edges), `group`
  (choice), `desc`. **`entry.Description` is EMPTY on CoA** → `desc` is resolved via
  `GetSpellDescription(spells[1])` at export (v0.3.5); in-game tooltips get it free from
  `SetSpellByID`, so this is export-only. `tools/extract_coa_talent_tree.py` →
  `coa_talent_tree.json` for the site; `tools/COA_TALENTS_CONTRACT.md`.
- **gotcha — <coa-ingame-tree>**: `ConLogs-CoA/ConLogsUI.lua` `RenderCoA`/`RenderCoATab`/
  `coaNodeSet`/`coaApplyShape` draw the node-graph in the Talents panel (source: `coaExport`, live
  `GetEntriesByClass` fallback), positioned on the x/y grid, picks highlighted, shape frames via
  `SetAtlas("talents-node-<shape>-<state>")` + icon `SetMask`. Gotchas: this client exposes **no
  `frame:CreateLine`** → edges are axis-aligned L-connectors (plain textures), not diagonals;
  background is ONE shared spec scene (`talents-background-<class>-<spec>` via
  `AtlasUtil:AtlasExists` — Class/General tabs have no atlas of their own, and without a background
  the greyed nodes are invisible → look "missing").

## Dev spike

- **Spike** → `ConLogsSpike.lua` — `/conlogs spike …` diagnostics (`pos`/`relay`/`size`/`unitpos`/
  `buffs`/`aura`/`coa`/`dump`). **Stripped from release zips** — see §Tools & release
  `<build-release>`. Uses the same `PRISTINE` taint-restore pattern as the relay.

## Tools & release

- **Tools inventory**: tracked = `tools/build_release.py` (release builder),
  `tools/extract_coa_talent_tree.py` (SV → site JSON), `tools/COA_TALENTS_CONTRACT.md` (site
  contract). `tools/coa_talent_tree.json` is GENERATED + gitignored (regenerate via the extractor).
  Local-only UNTRACKED dev files (replay decoder `track.js`, arena/BG map PNGs) are kept out of the
  public repo by design — dev/extraction tooling was stripped in commit b6518ba (docs/ToDo.md
  tracks their fate).
- **gotcha — <build-release>**: hand-built zips, no CI. (1) Bump BOTH `.toc ## Version` AND the Lua
  `ADDON_VERSION` constant. (2) Run **`python tools/build_release.py <addon_dir> <out.zip>`** — it
  whitelist-copies toc-listed files into staging and applies the two release-only transforms:
  drops `ConLogsSpike.lua` (+ `, ConLogsSpikeDB` from the SV line), and **strips
  developer/diagnostic slash commands** by deleting every `--@strip-dev-begin@ … --@strip-dev-end@`
  block from each `.lua` (currently the `dump`/`dumpspec`/`dumpstats`/`dumpentries` handlers;
  `aura` is deliberately KEPT — it's the one player-useful diagnostic). Dev source keeps all
  commands; only the zip is stripped. Always `luaparser`-verify the zip's `ConLogs.lua` after
  building (hub `<chunk-local-limit>`). (3) `gh release create`. A **minor** bump (2.x→2.(x+1).0)
  notifies users on older builds; **patch** bumps are silent (`CompareMajorMinor`). Workspace
  file-op traps while building: hub `<ps-path-guards>`.
- **gotcha — <version-display>**: `GetAddOnMetadata(addon,"Version")` reads the `.toc` cached at
  client LAUNCH and is NOT refreshed by `/reload` → minimap tooltip + version-ping show a stale
  number until a full restart. Fix: runtime version is the Lua constant `ADDON_VERSION`
  (re-executes on `/reload`), exposed as `_G.ConLogs.VERSION`. **KEEP `ADDON_VERSION` in sync with
  `.toc ## Version` on every release.**
- **gotcha — <coa-latest-trap>** (shared repo, ONE "Latest" flag): Epoch tags `v*`, CoA tags
  `coa-v*`, but the repo has a SINGLE GitHub "Latest" marker — `gh release create` moves it to the
  newest tag regardless of game, so `github.com/Defcons/ConLogsApp/releases/latest` returns
  whichever game published last. **The addons themselves are SAFE**: both `RELEASES_URL = "…/releases/"`
  (the listing page, NOT `/releases/latest`) — the in-game "newer version" nudge sends users to the
  full list to pick (verified 2026-07-08; the old note claiming Epoch's updater uses
  `/releases/latest` was wrong). The real risk is anything that consumes `/releases/latest` —
  notably the **epoglogs.com / coalogs.com download links** (separate web-app repo, NOT verifiable
  from here). **Proper fix:** each site resolves the latest release whose TAG PREFIX matches its
  game (`v*` vs `coa-v*`) via the GitHub `/releases` API, never `/releases/latest` — then the
  "Latest" flag is irrelevant and both sites always point right. **Interim workaround** (if a site
  still uses `/releases/latest`): after cutting a CoA release, re-mark Epoch latest —
  `gh release edit <epoch tag> --repo Defcons/ConLogsApp --latest`.
