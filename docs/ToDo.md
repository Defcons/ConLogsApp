# ToDo — ConLogsApp

<!-- STRICT deferral ledger (~/.claude/CLAUDE.md §5): the MOMENT anything is set aside /
     deferred / decided-not-now, it gets an entry here — session history routinely loses it.
     Lifecycle: done → check off, prune on the next touch. Never a write-only graveyard.
     Never mirror Testing.md — anything whose only remaining step is a human verdict lives
     there ALONE. -->

_Last verified: 2026-08-20 @ 4a58032 — first real fill: open items consolidated from the old
OrientationMap "Deferred / open" section + KB §8._

## Open

- [ ] **End-of-raid relay flush** — the true fix for post-final-kill starvation: a chunk lands
  only when someone fails a cast, so after the last boss nothing relays (Nav §Relay
  `<relay-rides-failed-casts>`, KB §2/§8). The out-of-combat relay + the loot-flush button
  (v2.7.0) only mitigate.
- [ ] **Server-side position replay viewer** — TS chunks land but nothing consumes them in
  production (KB §8). Local prototype = the untracked `tools/track.js` + map PNGs (see
  Blocked below); the production viewer would live in the web-app repo.
- [ ] **coalogs.com CoA talent rendering** — addon side is DONE (caBuild wire 45/46 +
  `coa_talent_tree.json`); the SITE must read `player.coaTalents` and draw the map per
  `tools/COA_TALENTS_CONTRACT.md`. Work lives in the separate web-app repo (KB §8).
- [ ] **License line fix** — `ConLogs-Epoch/README.md` ends with "MIT." but root `LICENSE` +
  root `README.md` are GPLv3 (authoritative — KB §8). One-line README fix on the next Epoch
  touch.

## Blocked / needs the user

- [ ] **Fate of untracked `tools/` working files** — `track.js` (relay→replay decoder),
  `NetherstormArena.png`, `WarsongGulch.png`, `preview.png`: in-flight BG/arena replay-viewer
  work sitting untracked since the dev/extraction tooling was stripped from the public repo
  (commit b6518ba). Decide: keep local-only (and optionally gitignore them explicitly), or
  home them somewhere private. Until decided they are one `git clean`/disk-loss away from
  gone.

## Done (prune on next touch)

(nothing yet)
