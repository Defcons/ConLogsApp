# ConLogsApp — Pending Tests (unconfirmed)

<!-- STRICT test queue (~/.claude/CLAUDE.md §5): every change that needs the user's own hands
     to confirm lands here, WITH repro steps + pass criteria (runnable cold) + what's already
     machine-verified. Confirmed → graduate to KnowledgeBase/ResearchJournal, then DELETE —
     this file holds ONLY what is not yet human-verified. -->

_Last verified: 2026-08-20 @ 4a58032 — first real fill: the one outstanding human check,
carried from KB §9._

## CoA: live-keystone DI capture probe

- **What**: confirm the `DI` difficulty capture end-to-end against a REAL active Mythic+
  keystone. All getters return 0/empty outside an active keystone, so the keystone branch has
  never been observed live (KB §6/§9; Nav §CoA fork `<coa-difficulty>`).
- **Repro (cold)**: dev build (spike NOT stripped) on the CoA client → start a dungeon run
  with a keystone ACTIVE → `/conlogs spike coa` → ensure `/combatlog` is on, then fail a cast
  at a pull (e.g. cast while moving).
- **Pass criteria**: (1) spike output shows `GetActiveKeystoneInfo` with keystoneLevel > 0,
  a dungeonID, and populated affixes; (2) `WoWCombatLog.txt` gains a `[[CL_DI_` chunk whose
  decoded payload carries keyActive=1, the key level, and the affix CSV (payload shape: Nav
  §CoA fork `<coa-difficulty>`).
- **Machine-verified already**: payload assembly, pcall-guarded degrade to `GetInstanceInfo`
  fields, land-gated dedup (one DI per run, dedup on content), top-priority enqueue at each
  pull.
