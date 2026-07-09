# CoA scaled item stats — relay spec (wire field 47)

_Addon side: **ConLogs-CoA v0.3.7+**. Status: shipped (`coa-v0.3.7`)._

## Problem

CoA (Ascension) scales an item's stats to the **wearer's level** — a level-10 and a
level-51 character wearing the same *Tigerstrike Mantle* have different actual stats.

The addon has always read the correct scaled values at scan time, but it funnelled them
into the **global, itemID-keyed item cache** (wire field 40, `BuildItemInfoHints` →
`ConLogsItemCacheDB` / `armory_items`). That table has **one row per item, shared by every
character**, so it's **last-scan-wins**: the armory shows whoever scanned the item most
recently, not the character you're viewing. (Symptom: the in-game Stats panel flags
`⚠ Item-only — values are lower than in-game` when the stored row was written by a
lower-level scanner.)

The fix re-homes the *same* scaled values **per equipped slot on the character's own scan**,
so the site can store them per-character and prefer them in the paperdoll.

## Wire field 47

Appended to the `^`-delimited CI payload at **position 47** (append-only tail, after
`45=caSpec` / `46=caBuild`). Built by `BuildScaledSlotStats(unit)` in `ConLogs.lua`.

```
<slotEntry>;<slotEntry>;...
```

Each `slotEntry`:

```
slot ~ itemID ~ itemLevel ~ TOKEN=val,TOKEN=val,...
```

| part        | meaning                                                                    |
|-------------|----------------------------------------------------------------------------|
| `slot`      | equip slot 1–19 (same numbering as the gear fields 12–30)                  |
| `itemID`    | numeric item id (also derivable from the slot's gear itemstring)           |
| `itemLevel` | **scaled** item level (`GetItemInfo(link)`; `0` if uncached at scan time)   |
| stats block | `,`-separated `TOKEN=value` pairs, the same set as the field-40 item hints  |

- **Stats tokens** are exactly `GetItemStats(link)`'s keys on this client: `ITEM_MOD_*_SHORT`
  (STRENGTH/AGILITY/STAMINA/INTELLECT/SPIRIT and the rating stats), `RESISTANCE0_NAME` (armor),
  Ascension customs like `PVE_POWER`, etc. Values are the raw scaled numbers.
- Only equipped slots that have stats are emitted. If none, the field is the empty string.
- **Wire-safe:** no `^` (field separator) or `|` (item-link escape); delimiters are `;` / `~` / `,` / `=`.

### Example

```
1~9375~51~ITEM_MOD_STRENGTH_SHORT=45,RESISTANCE0_NAME=1204,ITEM_MOD_CRIT_RATING_SHORT=20;3~7718~51~ITEM_MOD_STAMINA_SHORT=30,ITEM_MOD_ATTACK_POWER_SHORT=54
```

## How it travels

- Stored on the received record as **`set.slotStats`** (raw string) in `ConLogsDB`.
- Carried verbatim in the combat-log CI relay (the relay re-emits `rawPayload`), so it appears
  in uploads with no extra handling.
- These are the **same values** as field 40's `statsStr`, just keyed by slot on the character
  instead of globally by itemID — no new tooltip scan, no added per-frame cost.

## Site side (to build)

1. Parse field 47 into `{ [slot] = { itemID, itemLevel, stats{TOKEN:value} } }` for the character.
2. Store it **per character** (not in the shared `armory_items` row).
3. In the paperdoll, **prefer the per-character slot stats**; **fall back** to the global
   itemID row only when field 47 is absent (older scans / older addons).

## Compatibility

Purely additive. Scans from pre-v0.3.7 addons have no field 47 → the site uses today's
behavior (global row). No change to existing fields or their semantics.
