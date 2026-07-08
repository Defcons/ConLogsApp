# Code Map — ConLogsApp

<!--
  A THIN, POINTER-BASED index of this codebase. Read first, update after changes.
  Rules (from ~/.claude/CLAUDE.md §5):
    - Anchor to SYMBOL names, never line numbers — they rot.
    - Only include what's expensive to rediscover: the map + invariants + gotchas + contracts.
    - Leave OUT anything re-derivable in ~10s by opening the named file. No per-function prose.
    - Update this file in the SAME diff that changes structure/behaviour, and bump the stamp below.
-->

_Last verified: 2026-07-08 @ d107cc0 — by Claude (Opus 4.8); CoA talent capture + map + in-game tree_

## What this is
Client-side apps for the **ConLogs** logging platform (formerly *EpogArmory* / *epoglogs*). The web
app lives in a separate `ConLogs`/`epoglogs` repo; data currently uploads to epoglogs.com. This repo
holds two WoW 3.3.5 **Lua addons** (no build step, no bundler) plus decode/replay `tools/`.

- **`ConLogs-Epoch/`** — the addon for **Project Epoch** (formerly EpogArmory). Mesh gear/talent
  inspector + combat-log relay. Loaded from `…/resources/epoch_live/Interface/AddOns/`.
- **`ConLogs-CoA/`** — sibling fork for **Conquest of Azeroth** (CoA, an Ascension client mode).
  Rebrand-only fork of Epoch + M+ difficulty capture. Loaded from the SHARED
  `…/resources/client/Interface/AddOns/` (NOT `ascension_ptr/…`) — see [[coa-live-folder]].
- **`tools/`** — server-side/offline decode helpers: `track.js` (wire→armory), `extract_coa_talent_tree.py`,
  `coa_talent_tree.json`, `COA_TALENTS_CONTRACT.md`, map PNGs. (Untracked working files may exist here.)

**Durable design decision (belongs here, not version logs):** the model is **addon-relay + manual
single-file upload — NO companion executable, NO server-side memory reading.** A Go desktop companion
was prototyped for live streaming, then **dropped** (commit ccc791f): the relay makes `WoWCombatLog.txt`
self-contained, and an addon can't upload anyway. Positions/gear/etc. must come from an in-game addon
because reading game memory server-side is not permitted. (Release versions/status are intentionally
kept OUT of this map — see the repo's GitHub Releases + `.toc ## Version`.)

## Subsystems (where things live)
Load order is set by each addon's `.toc`. Epoch: `ConLogs.lua` → `ConLogsUI.lua` → `ConLogsDummy.lua`
→ `ConLogsDungeon.lua` → `ConLogsRelay.lua` → `ConLogsSpike.lua`. CoA drops Dummy/Dungeon, adds
`ConLogsAutoLog.lua`.

- **Core / mesh / storage** → `ConLogs.lua` (~4000 lines). Addon-message mesh (scan groupmates →
  broadcast gear/talents → store in `ConLogsDB`), version ping, legacy `EpogArmoryDB` import.
  Key symbols: `PREFIX` (`"EpogArmory"` literal — see [[mesh-prefix-literal]]), `ADDON_VERSION`
  (Lua constant — see [[version-display]]), `CheckFullSet`, `PruneStoredData` (see [[sv-prune]]),
  `CompareMajorMinor`. Slash root: `SlashCmdList["CONLOGS"]` = `/conlogs` (+ `/epogarmory` alias).
- **Browser / inspect UI** → `ConLogsUI.lua` — paperdoll browser, per-spec gear sets, minimap shield.
- **Relay transport** → `ConLogsRelay.lua` — the SPELL_CAST_FAILED relay (see [[relay-transport]]).
  Key symbols: `PREFIX_FAMILY` (`"[[CL_"`), per-kind prefixes `CI/TS/BU/LT/VR/PO_PREFIX`,
  `FAILEDTYPE_ARG = 12`, `FAIL_GLOBALS`, `PRISTINE` (taint restore), `POS_PREFIX = "ConLogsPos"`,
  `enqueueGroupCI`/`enqueueBuffs`/`enqueueVersion`/`enqueuePetOwners`.
- **Dummy DPS parse** (Epoch only) → `ConLogsDummy.lua` — training-dummy DPS test; owns `LoggingCombat`
  carefully (`dummyStartedLog` guard).
- **Dungeon/raid tracker** (Epoch only) → `ConLogsDungeon.lua` — `DUNGEONS` roster table keyed by
  `GetInstanceInfo()` name; auto-`/combatlog`; loot reminder. See [[instance-detection]].
- **Auto-logging** (CoA only) → `ConLogsAutoLog.lua` — replaces the Epoch dungeon module: auto-START
  `/combatlog` on entering ANY instance, auto-STOP on leaving instance/group; gated by
  `ConLogsDB.config.raidAutoLog` (`/conlogs raidlog`).
- **CoA difficulty capture** (CoA only) → `ConLogs-CoA/ConLogsRelay.lua` `enqueueDifficulty` — see
  [[coa-difficulty]].
- **Dev-only spike** → `ConLogsSpike.lua` — `/conlogs spike …` diagnostics (`pos`/`relay`/`size`/
  `unitpos`/`buffs`/`aura`/`coa`/`dump`). **Stripped from release zips** — see [[build-release]].

## Invariants & gotchas
- **<mesh-prefix-literal>**: the mesh addon-message `PREFIX` is kept the literal string `"EpogArmory"`
  in BOTH addons (`ConLogs.lua`) so renamed/CoA clients still sync with any legacy EpogArmory peer.
  **DO NOT change it.** The position mesh uses a SEPARATE `POS_PREFIX = "ConLogsPos"` so positions
  never hit the gear-reassembly path.
- **<relay-transport>**: data rides the **SPELL_CAST_FAILED relay** — the addon overwrites the
  `SPELL_FAILED_*` global error strings with base64 chunks; the next *failed* cast makes the engine
  write that string as the CLEU `failedType` field (**arg index 12** on PE, ~1023 chars, ~950 usable
  after the ~60-char header). Chunk header `[[CL_<KIND>_v1_<session>_<id>_<seq>/<total>]]<b64>`.
  Kinds: `CI` gear/talents/stats, `BU` buff+totem auras, `TS` positions, `LT` loot, `VR` version,
  `PO` pet→owner (Epoch), `DI` difficulty (CoA). No LibDeflate on PE → no compression.
- **<relay-rides-failed-casts>**: a chunk lands ONLY when a player fails a cast. **After the final
  boss kill nobody casts → nothing relays → end-of-raid loot never lands** (architectural limit, not
  a bug). A low-casting or immediately-logging-out player relays little. An end-of-raid flush is the
  open fix. (As of the out-of-combat change the relay also runs out of combat so post-kill loot can
  ride a *later* failed cast.)
- **<land-gated-dedup>**: per-version/per-unit dedup baselines (`relayedVersion`, `relayedBuffs`)
  advance ONLY when a chunk is **confirmed landed** (via an `onLand` callback fired from `onFailed`
  when landed-evidence — a later failedType starting with `[[CL_` — is seen), NEVER at enqueue.
  Advancing at enqueue = silent permanent data loss if the chunk never lands. Also: on ring-cap
  front-eviction (`table.remove(queue,1)`) you MUST reset `pending=nil` or the next failed cast
  credits an innocent chunk as landed.
- **<taint-pristine-restore>**: overwriting `SPELL_FAILED_*` taints the secure cast path (errors +
  UIErrorsFrame red text are suppressed). Capture the **PRISTINE** globals ONCE at file load
  (`PRISTINE = {}`, populated from `_G[g]` before any overwrite) and ALWAYS restore to those — never
  a value read at first-overwrite (could be a stale chunk string). Restore unconditionally on
  `PLAYER_LEAVING_WORLD` + `PLAYER_LOGOUT`. Same pattern in `ConLogsSpike.lua`.
- **<pe-capture-gotchas>** (why captures work the way they do on the Project Epoch client):
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
- **<chunk-local-limit>**: `ConLogs.lua`'s main chunk sits right at Lua 5.1's **200-file-scope-local
  cap**. Adding bare module-level `local`s can push it over → the file silently fails to COMPILE and
  the whole addon never loads (`/conlogs` → "unknown command", no SV write — looks like the addon
  vanished). Put new module-level helpers on a TABLE (e.g. `CoaBuild.*`), not bare `local function`.
  Verify after edits with `luaparser` (count `LocalFunction`+`LocalAssign` targets directly under the
  main chunk; must stay ≤200). No lua binary here — `pip install luaparser`.
- **<sv-prune>**: 3.3.5 silently drops a WHOLE SavedVariable that exceeds an internal size limit.
  `PruneStoredData()` runs at `PLAYER_LOGIN`: age-prune player records (>45d), count-cap 4000 (drop
  oldest), age-prune item cache (>60d), drop orphan `lastScanned`.
- **<version-display>**: `GetAddOnMetadata(addon,"Version")` reads the `.toc` cached at client LAUNCH
  and is NOT refreshed by `/reload` → minimap tooltip + version-ping show a stale number until a full
  restart. Fix: runtime version is the Lua constant `ADDON_VERSION` (re-executes on `/reload`),
  exposed as `_G.ConLogs.VERSION`. **KEEP `ADDON_VERSION` in sync with `.toc ## Version` on every
  release.**
- **<mesh-hardening>**: reassembler bounds untrusted wire input (reject `total>64` / out-of-range
  `idx`, cap concurrent reassembly buffers at 200). Anti-abuse cooldowns key on the authenticated
  `CHAT_MSG_ADDON` `sender` (4th arg), NOT the spoofable wire `requester` field.
- **<instance-detection>** (Epoch `ConLogsDungeon.lua`): `DUNGEONS` keyed by `GetInstanceInfo()` name.
  **Baradin Hold trap**: PE returns `GetInstanceInfo()="Tol Barad"` (parent) + `type="party"`;
  `DetectDungeon` falls back to `GetRealZoneText()` when the info name misses the roster. Diagnose
  with `/conlogs dungeondebug`.

## CoA-specific (ConLogs-CoA/)
- **<coa-live-folder>**: the CoA client loads addons from the SHARED `…/resources/client/Interface/
  AddOns`, NOT `ascension_ptr/…`. SV = `…/client/WTF/Account/<ACCT>/SavedVariables/ConLogs-CoA.lua`.
- **<coa-difficulty>**: CoA backports a retail Mythic+ API. `enqueueDifficulty` relays one land-gated,
  top-priority `[[CL_DI_` chunk per run (dedup on content) at each pull. Source getter
  `C_MythicPlus.GetActiveKeystoneInfo()` → `{keystoneLevel, dungeonID, rewardMultiplier,
  activeAffixes}` (0/empty outside a keystone). `GetCurrentAffixes()` is the WEEKLY pool (populates
  even on normal runs → only trust affixes when a keystone is active). All getters are pcall-guarded
  → degrade to `GetInstanceInfo` fields. Payload: `DI|<getTimeMs>|<unixSec>|<name>^<type>^<giDiff>^
  <maxPlayers>^<group>^<keyActive>^<keyLevel>^<affixCSV>^<mapAreaID>^<dungeonID>^<difficultyName>`.
  `GetMapFinalEncounter(mapID)` needs the keystone dungeon mapID (returns 0/{} for a world-area id),
  so the run goal is resolved server-side from static CoA data, not live. CoA marker:
  `GetRealmName()` contains "Conquest of Azeroth".
- **<coa-fullset-relaxed>**: Epoch's `CheckFullSet` required 16 slots + avg ilvl ≥55, which blocked
  ALL storage on CoA (leveling gear). CoA relaxes to `COA_MIN_EQUIPPED_SLOTS = 5`, no ilvl floor.
- **CoA removed vs Epoch**: dungeon-run tracker + training-dummy deleted (`ConLogsDungeon.lua` +
  `ConLogsDummy.lua` absent from the fork; `/conlogs dummy|dungeon|dungeondebug` gone). Auto-logging
  moved to `ConLogsAutoLog.lua`.
- **<coa-talents>** (talent CAPTURE, fixed — the old `{0,0,0}` legacy read is dead): CoA does NOT use
  `GetTalentInfo` (empty for CoA classes) nor DF `C_Traits` — it uses Ascension's custom
  **`C_CharacterAdvancement`**. `ConLogs.lua` `CoaBuild` table: `CoaBuild.Encode(unit)` →
  `"L:"+nodeId:rank,…` via `GetInspectedBuild(unit, spec)` (authoritative for ANY class incl.
  Wildwalker/Primalist; self is warmed by `CoaBuild.Warm`=`InspectUnit("player")` at
  login/PLAYER_TALENT_UPDATE/self-scan; iterate-`GetAllEntries` only as fallback). Wire **45=caSpec,
  46=caBuild** (append-only tail); stored `set.caSpec/caBuild`; rides the CI relay unchanged. Respec
  re-scan forced by clearing `lastSelfFingerprint` (the legacy fingerprint can't see CoA talent
  changes). Full external-API notes: ~/.claude memory `reference_coa_talent_api.md`.
- **<coa-talent-map>**: `/conlogs dumpentries` exports the full node map to
  **`ConLogsTalentTreeDB.coaExport.nodes[]`** — written into that EXISTING SV on purpose (a NEW
  top-level SV won't register on this client without a full restart, so it never persisted). Node
  source = **`GetEntriesByClass(class,tab,false)`** (the FULL set incl. ABILITY nodes — what the
  in-game tree uses; `GetTalentsByClass` is talents-ONLY and silently drops abilities like
  Bearskin/Natural Efficiency) swept over all DBC class×spec combos, ∪ `GetAllEntries` ∪
  `GetEntryByInternalID` over every seen pick. Per node: id, name, icon(basename), nodeType, x/y
  (custom classes, integer grid 0–10 × 0–9) or col/row (default), **`connected[]` = THE tree edges**
  (from `entry.ConnectedNodes`; `parent`/`requires` are near-empty — NOT the edges), `group` (choice),
  `desc`. **`entry.Description` is EMPTY on CoA** → `desc` is resolved via `GetSpellDescription(spells[1])`
  at export (v0.3.5); in-game tooltips get it free from `SetSpellByID`, so this is export-only.
  `tools/extract_coa_talent_tree.py` → `coa_talent_tree.json` for the site; `COA_TALENTS_CONTRACT.md`.
- **<coa-ingame-tree>**: `ConLogsUI.lua` `RenderCoA`/`RenderCoATab`/`coaNodeSet`/`coaApplyShape` draw
  the node-graph in the Talents panel (source: `coaExport`, live `GetEntriesByClass` fallback),
  positioned on the x/y grid, picks highlighted, shape frames via `SetAtlas("talents-node-<shape>-<state>")`
  + icon `SetMask`. Gotchas: this client exposes **no `frame:CreateLine`** → edges are axis-aligned
  L-connectors (plain textures), not diagonals; background is ONE shared spec scene
  (`talents-background-<class>-<spec>` via `AtlasUtil:AtlasExists` — Class/General tabs have no atlas
  of their own, and without a background the greyed nodes are invisible → look "missing").

## Contracts between modules
- **Addon relay → epoglogs server**: the addon emits `[[CL_<KIND>_v1_…]]<b64>` chunks in the combat
  log; the server (`js/conlogs-relay.js` RelayReassembler + `lib/conlogs-wire-parser.js`
  `parseWirePayload`) reassembles and decodes. **Wire format trap**: the outer per-tab array is
  **1-based** (`[null, tab1, tab2, tab3]`); inner per-tab arrays are **0-based** — reading
  `ranks[talent.index]` 1-based drops the first talent and shifts the whole tree. Server-side
  data-coverage/decode gotchas (loot Epic+-only + cross-log dedup, totem-aura self-only propagation,
  talent 0-based) live in the **web app repo**, not here.
- **Mesh interop**: any client on `PREFIX="EpogArmory"` interoperates — ConLogs-Epoch, ConLogs-CoA,
  and legacy EpogArmory all share the reassembly path (CoA is a separate client so no name collision
  despite identical SV/PREFIX names).
- **<coa-latest-trap>** (shared repo, ONE "Latest" flag): Epoch tags `v*`, CoA tags `coa-v*`, but the
  repo has a SINGLE GitHub "Latest" marker — `gh release create` moves it to the newest tag regardless
  of game, so `github.com/Defcons/ConLogsApp/releases/latest` returns whichever game published last.
  **The addons themselves are SAFE**: both `RELEASES_URL = "…/releases/"` (the listing page, NOT
  `/releases/latest`) — the in-game "newer version" nudge sends users to the full list to pick (verified
  2026-07-08; the old note here claiming Epoch's updater uses `/releases/latest` was wrong). The real
  risk is anything that consumes `/releases/latest` — notably the **epoglogs.com / coalogs.com download
  links** (separate web-app repo, NOT verifiable from here). **Proper fix:** each site resolves the
  latest release whose TAG PREFIX matches its game (`v*` vs `coa-v*`) via the GitHub `/releases` API,
  never `/releases/latest` — then the "Latest" flag is irrelevant and both sites always point right.
  **Interim workaround** (if a site still uses `/releases/latest`): after cutting a CoA release, re-mark
  Epoch latest — `gh release edit <epoch tag> --repo Defcons/ConLogsApp --latest`.

## Known landmines / deferred
- **<build-release>**: hand-built zips, no CI. (1) Bump BOTH `.toc ## Version` AND the Lua
  `ADDON_VERSION` constant. (2) Build the zip EXCLUDING `ConLogsSpike.lua` + stripping
  `, ConLogsSpikeDB` from the SV line + the `ConLogsSpike.lua` load line — **whitelist-copy** wanted
  files into a staging dir (never copy-all-then-delete). (3) `gh release create`. A **minor** bump
  (2.x→2.(x+1).0) notifies users on older builds; **patch** bumps are silent (`CompareMajorMinor`).
  **PowerShell path-guard traps in this workspace**: `Remove-Item -Recurse` on staging/AddOns paths
  and `Select-String` get BLOCKED (sometimes silently, exit 1). Use whitelist `Copy-Item -Force` and
  the Grep/Read tools (not Select-String/Get-Content). `zip` is NOT in the git-bash here → build with
  `python -c "import shutil; shutil.make_archive(...)"`. Also clean-sync source into the live AddOns
  folder on every change.
- **Deferred / open**: server-side position replay viewer (TS not consumed yet); end-of-raid relay
  flush (see [[relay-rides-failed-casts]]); **CoA talent rendering on coalogs.com** — addon side is
  done (caBuild + `coa_talent_tree.json`), the site must read `player.coaTalents` + draw the map per
  `COA_TALENTS_CONTRACT.md`; live-keystone probe (`/conlogs spike coa` inside an active M+).
- **License inconsistency (flag)**: root `LICENSE` + root `README.md` say **GPLv3**;
  `ConLogs-Epoch/README.md` still says **MIT**. Treat GPLv3 (the actual `LICENSE` file) as
  authoritative; the subfolder README line is stale.
