# Knowledge Base — ConLogsApp

<!--
  The distilled, canonical TRUTH about how the ConLogs addon platform behaves:
  the wire protocol, the capture mechanics, the design decisions, the numbers.
  The MODEL of the triad — CodeMap = the machine (where code lives, edit-time
  landmines) · KnowledgeBase = the model (what's TRUE about the system) ·
  ResearchJournal = the history (how it got built). Cross-link, don't copy: code
  navigation + "DO NOT edit this" landmines stay in ../CodeMap.md; this file
  records confirmed BEHAVIOUR with confidence + a pointer to the owning symbol.
-->

_Last verified: 2026-08-03 @ cb5004d — seeded from code inspection (Epoch v3.0.1,
CoA v0.3.7), CodeMap, README, the field-47 spec, and the full git history — by
Claude Opus 4.8._

_The triad: **[CodeMap](../CodeMap.md) = the machine · KnowledgeBase = the model
· [ResearchJournal](ResearchJournal.md) = the history.**_

## How to read this doc

Every claim is tagged and scored — **never mix the tiers**:
- **[FACT, NN%]** — confirmed by code inspection or shipped/verified behaviour.
- **[HYP, NN%]** — hypothesis; carries confidence + evidence + the test that settles it.
- **[ASSUMPTION]** — believed but unverified; flagged for challenge.
- **[UNKNOWN]** — an open question (see §9).

Confidence: 20% weak · 40% some · 60% likely · 80% strong · 95% almost certain ·
100% repeated/shipped. **Anti-drift:** where a number is code-owned (a `.toc`
version, a Lua constant, an arg index) this file RECORDS it with a symbol pointer
and is trust-but-verify — code wins a conflict; correct the KB.

---

## 1. What this system is (the one durable decision)

- **[FACT, 100%]** ConLogsApp ships **two client-side WoW 3.3.5 Lua addons** and
  offline `tools/` — no build step, no bundler. `ConLogs-Epoch/` (Project Epoch,
  formerly *EpogArmory*) and `ConLogs-CoA/` (Conquest of Azeroth, an Ascension
  client). The consuming **web app is a separate repo** (`epoglogs`/`coalogs`);
  data reaches it by a human uploading a single `WoWCombatLog.txt`.
- **[FACT, 100%] The architecture is addon-relay + manual single-file upload —
  NO companion executable, NO server-side memory reading.** A Go desktop
  companion was prototyped and **dropped the same day** (2026-06-02, commit
  `ccc791f`). The reasoning is the load-bearing decision of the whole project:
  reading game memory server-side is not permitted, and an addon cannot upload a
  file, so **everything the site needs (gear, talents, buffs, positions, loot,
  difficulty) must be embedded INTO the combat log by the addon** — which makes
  the uploaded file self-contained and removes any need for an external app.
- **[FACT, 100%]** Current shipped versions: **Epoch `3.0.1`**, **CoA `0.3.7`** —
  `ADDON_VERSION` Lua constant in each `ConLogs.lua`, mirrored in the `.toc
  ## Version`. Both MUST be bumped together on release (see §7).

## 2. The relay wire protocol (the heart of the system)

- **[FACT, 100%] Transport = the SPELL_CAST_FAILED relay.** The addon overwrites
  the global `SPELL_FAILED_*` error strings with base64 chunks; the engine writes
  the active override into the CLEU `failedType` field on the **next failed
  cast**, so the chunk lands in the combat log. `failedType` is **CLEU arg index
  12** on Project Epoch (`FAILEDTYPE_ARG = 12`, spike-confirmed). —
  `ConLogsRelay.lua`.
- **[FACT, 95%] Chunk budget:** the failedType string holds **~1023 chars**, of
  which **~950 are usable** after the ~60-char header. Header shape:
  `[[CL_<KIND>_v1_<session>_<id>_<seq>/<total>]]<b64>`; the family prefix
  `PREFIX_FAMILY = "[[CL_"` is what the reassembler and the land-detector match
  on. **No LibDeflate on PE → no compression** (raw base64). — `ConLogsRelay.lua`.
- **[FACT, 100%] Seven chunk KINDS**, each a `<KIND>` in the header:
  | Kind | Payload | Addon |
  |---|---|---|
  | `CI` | gear + talents + stats (the big one) | both |
  | `BU` | buff + totem auras (consumables/jujus) | both |
  | `TS` | positions (mesh-of-self) | both |
  | `LT` | dropped loot | both |
  | `VR` | addon version, once per session | both |
  | `PO` | pet → owner mapping | Epoch |
  | `DI` | M+ difficulty / keystone context | CoA |
- **[FACT, 100%] Land-gated dedup (the correctness invariant).** Per-version /
  per-unit dedup baselines (`relayedVersion`, `relayedBuffs`, …) advance ONLY
  when a chunk is **confirmed landed** — an `onLand` callback fired from
  `onFailed` when landed-evidence (a later `failedType` starting with `[[CL_`) is
  observed — **never at enqueue**. Advancing at enqueue = silent permanent data
  loss if the chunk never lands. On ring-cap front-eviction the `pending` slot
  MUST be reset or the next failed cast miscredits an innocent chunk. —
  `ConLogsRelay.lua`; edit-time detail in [CodeMap `<land-gated-dedup>`](../CodeMap.md).
- **[FACT, 95%] Architectural limit: relay rides failed casts, so it can starve.**
  A chunk lands only when a player fails a cast. **After the final boss kill
  nobody casts → nothing relays → end-of-raid loot can miss** (mitigated, not
  cured: the relay now also runs out of combat so post-kill loot can ride a
  *later* failed cast; a true end-of-raid flush is the open fix). Low-casting or
  instantly-logging-out players relay little.
- **[FACT, 95%] Taint safety.** Overwriting `SPELL_FAILED_*` taints the secure
  cast path (errors + red UIErrorsFrame text are suppressed). The **PRISTINE**
  globals are captured ONCE at file load and always restored to those (never to a
  value read at first-overwrite, which could be a stale chunk), unconditionally on
  `PLAYER_LEAVING_WORLD` + `PLAYER_LOGOUT`. — `PRISTINE`, `ConLogsRelay.lua` +
  `ConLogsSpike.lua`.

## 3. Capture mechanics — why each capture works the way it does (Project Epoch)

- **[FACT, 90%] Pre-pull buffs fire no `SPELL_AURA_APPLIED`** → the addon
  **snapshots** self+pet auras at each pull (`PLAYER_REGEN_DISABLED`), rather than
  relying on live aura events.
- **[FACT, 90%] Jujus + totem buffs emit NO combat-log aura events at all** → a
  periodic **3s aura poll** relays a unit only when its aura-set CHANGES
  (dedup-on-change); the server reconstructs buff windows from the edges.
  `UnitAura(unit,i,"HELPFUL")` returns the spellId at index 11 on 3.3.5.
- **[FACT, 90%] Positions use a mesh-of-self** because PE has **no `UnitPosition`**
  and `GetPlayerMapPosition` returns only *self* inside PvE instances (others read
  0,0). Each client broadcasts its own position over the dedicated
  `POS_PREFIX = "ConLogsPos"`; the logger aggregates. **Map-validity guard:** relay
  nothing when `GetMapInfo()` is a continent/world name (Kalimdor/Azeroth/…) — e.g.
  Onyxia has no instance map and falls back to "Kalimdor".
- **[FACT, 100%] The mesh gear/talent prefix is the literal `"EpogArmory"`** in
  BOTH addons — kept so renamed/CoA clients still sync with any legacy EpogArmory
  peer. Positions ride the SEPARATE `POS_PREFIX` so they never hit the gear
  reassembly path. Any client on `PREFIX="EpogArmory"` interoperates (CoA is a
  separate client, so identical SV/PREFIX names never collide).

## 4. Platform limits that shape the code (WoW 3.3.5 / Lua 5.1)

- **[FACT, 95%] 3.3.5 silently drops a WHOLE SavedVariable that exceeds an
  internal size limit** — hence `PruneStoredData()` at `PLAYER_LOGIN`:
  age-prune player records (>45d), count-cap 4000 (drop oldest), age-prune item
  cache (>60d), drop orphan `lastScanned`. — `ConLogs.lua`.
- **[FACT, 95%] Lua 5.1 caps a chunk at 200 file-scope locals.** `ConLogs.lua`'s
  main chunk sits right at that cap; a bare module-level `local` can push it over,
  and the file then **silently fails to COMPILE** — the whole addon never loads
  (`/conlogs` → "unknown command", no SV write). New module-level helpers go on a
  TABLE (e.g. `CoaBuild.*`), never bare `local function`. This bit CoA once
  (v0.2.6 fix). Verify with `luaparser` (`pip install luaparser`; no lua binary
  here). — [CodeMap `<chunk-local-limit>`](../CodeMap.md).
- **[FACT, 95%] `GetAddOnMetadata("Version")` reads the `.toc` cached at client
  LAUNCH and is NOT refreshed by `/reload`** → the minimap tooltip / version-ping
  would show a stale number until a full restart. Fix: the runtime version is the
  Lua constant `ADDON_VERSION` (re-executes on `/reload`), exposed as
  `_G.ConLogs.VERSION`. Keep it in sync with the `.toc` on every release.

## 5. Reassembly & site contract (server side lives in the web-app repo)

- **[FACT, 90%]** The addon emits `[[CL_<KIND>_v1_…]]<b64>` chunks; the server
  (`js/conlogs-relay.js` RelayReassembler + `lib/conlogs-wire-parser.js`
  `parseWirePayload`, in the SEPARATE web-app repo) reassembles + decodes.
- **[FACT, 90%] Wire-format trap:** the outer per-tab talent array is **1-based**
  (`[null, tab1, tab2, tab3]`); inner per-tab arrays are **0-based**. Reading
  `ranks[talent.index]` as 1-based drops the first talent and shifts the whole
  tree.
- **[FACT, 100%] The reassembler bounds untrusted wire input** (reject `total>64`
  / out-of-range `idx`; cap concurrent reassembly buffers at 200). Anti-abuse
  cooldowns key on the authenticated `CHAT_MSG_ADDON` `sender`, NOT the spoofable
  wire `requester` field. — `<mesh-hardening>`.

## 6. CoA differences (ConLogs-CoA/ — the sibling fork)

- **[FACT, 100%]** CoA loads from the SHARED `…/resources/client/Interface/AddOns`
  (NOT `ascension_ptr/…`); SV = `…/client/WTF/…/ConLogs-CoA.lua`. It **drops** the
  Epoch dungeon-run tracker + training-dummy and **adds** `ConLogsAutoLog.lua`
  (auto-`/combatlog` on entering ANY instance, stop on leaving; gated by
  `raidAutoLog`). Marker: `GetRealmName()` contains "Conquest of Azeroth".
- **[FACT, 95%] Talents use Ascension's custom `C_CharacterAdvancement`**, NOT
  `GetTalentInfo` (empty for CoA classes) nor DF `C_Traits`. `CoaBuild.Encode` →
  `"L:"+nodeId:rank,…` via `GetInspectedBuild(unit,spec)` — authoritative for any
  class incl. Wildwalker/Primalist (the old `{0,0,0}` legacy read was dead). Wire
  fields **45=caSpec, 46=caBuild**, append-only tail on the CI relay.
- **[FACT, 100%] Wire field 47 = per-slot scaled item stats** (v0.3.7). CoA scales
  item stats to the wearer's LEVEL, so the same item on a L10 vs a L51 character
  differs. The global itemID-keyed cache (field 40) is last-scan-wins → the armory
  showed whoever scanned most recently. Field 47 re-homes the SAME
  `GetItemStats(link)` values **per equipped slot on the character's own scan**
  (`slot~itemID~itemLevel~TOKEN=val,…;…`, stored `set.slotStats`), so the site can
  store per-character. Purely additive; no new tooltip scan. — full spec:
  [`COA-SCALED-ITEM-STATS-RELAY-SPEC.md`](COA-SCALED-ITEM-STATS-RELAY-SPEC.md).
- **[FACT, 95%] DI difficulty capture:** one land-gated top-priority `[[CL_DI_`
  chunk per run (dedup on content) at each pull, from
  `C_MythicPlus.GetActiveKeystoneInfo()` (keystone level / dungeonID / affixes;
  0/empty outside a keystone). Only trust affixes when a keystone is active
  (`GetCurrentAffixes()` is the WEEKLY pool). All getters pcall-guarded → degrade
  to `GetInstanceInfo`. Run goal is resolved server-side from static CoA data (the
  live `GetMapFinalEncounter` needs a keystone mapID).
- **[FACT, 95%] `CheckFullSet` is relaxed on CoA** to `COA_MIN_EQUIPPED_SLOTS = 5`,
  no ilvl floor — Epoch's 16-slots + avg ilvl ≥55 blocked ALL storage on CoA
  leveling gear (the "empty gear relay" bug).
- **[FACT, 90%] In-game CoA talent tree rendering** (`ConLogsUI.lua` `RenderCoA`)
  draws the node-graph from the `coaExport` node map (source
  `GetEntriesByClass(class,tab,false)` = the FULL set incl. ability nodes;
  `GetTalentsByClass` is talents-only and drops abilities). Constraints: this
  client exposes **no `frame:CreateLine`** → edges are axis-aligned L-connectors,
  not diagonals; every tab shares ONE spec background scene (Class/General tabs
  have no atlas → without it their greyed nodes look "missing"). `entry.Description`
  is EMPTY on CoA → node descriptions resolved via `GetSpellDescription` at export.
  `tools/extract_coa_talent_tree.py` → `coa_talent_tree.json` for the site;
  contract in `tools/COA_TALENTS_CONTRACT.md`.

## 7. Release model

- **[FACT, 95%] Hand-built zips, no CI.** (1) Bump BOTH `.toc ## Version` AND the
  Lua `ADDON_VERSION`. (2) `python tools/build_release.py <addon_dir> <out.zip>` —
  whitelist-copies toc-listed files and applies two release-only transforms: drops
  `ConLogsSpike.lua` (+ its SV) and strips `--@strip-dev-begin@ … --@strip-dev-end@`
  blocks (the `dump*` diagnostics; `aura` is deliberately KEPT). Dev source keeps
  everything; only the zip is stripped. `luaparser`-verify the zip's `ConLogs.lua`.
  (3) `gh release create`. A **minor** bump notifies users on older builds;
  **patch** bumps are silent (`CompareMajorMinor`).
- **[FACT, 90%] Two-game "Latest" trap.** Epoch tags `v*`, CoA tags `coa-v*`, but
  the repo has ONE GitHub "Latest" marker — `gh release create` moves it to the
  newest tag regardless of game. **The addons themselves are SAFE** (both point
  users at `…/releases/` the listing page, not `/releases/latest`). The real risk
  is anything consuming `/releases/latest` — notably the epoglogs.com /
  coalogs.com download links (separate repo). Proper fix: each site resolves the
  latest release whose TAG PREFIX matches its game via the `/releases` API.

## 8. Confirmed issues — OPEN

- **[OPEN]** No end-of-raid relay flush — post-final-kill loot can miss because
  nobody casts (§2). The one true fix; the out-of-combat relay only mitigates.
- **[OPEN]** Server-side position replay is not consumed yet (TS chunks land, the
  viewer is a prototype in `tools/` only).
- **[OPEN]** CoA talent rendering on **coalogs.com** — the addon side is done
  (caBuild + `coa_talent_tree.json`); the site must read `player.coaTalents` and
  draw the map per `COA_TALENTS_CONTRACT.md`. (Not verifiable from this repo.)
- **[OPEN, flag] License inconsistency:** root `LICENSE` + root `README.md` say
  **GPLv3**; `ConLogs-Epoch/README.md` still says **MIT**. GPLv3 (the actual
  `LICENSE`) is authoritative; the subfolder line is stale.

## 9. Open questions / future experiments

- **[UNKNOWN]** Live-keystone probe: run `/conlogs spike coa` inside an ACTIVE M+
  to confirm the DI capture end-to-end against a real keystone.
- **[UNKNOWN]** Exact usable-payload figure per chunk under real raid conditions
  (the ~950 usable is a derived estimate; measure against a full CI payload).
- **[UNKNOWN]** Whether the site consumes field 47 / caBuild yet (site-repo work,
  not visible here).

## 10. Confidence summary

Best-understood (≥95%): the addon-relay architecture decision, the wire
transport + chunk kinds, land-gated dedup, the platform limits (SV size, 200-local
cap, stale `.toc` version), the CoA field-45/46/47 additions, and the release
model. Weakest (UNKNOWN): anything on the SITE side of the contract (separate
repo) and the live-keystone DI capture — the priority for the next hands-on
verification pass.
