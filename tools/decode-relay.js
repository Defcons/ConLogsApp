#!/usr/bin/env node
// decode-relay.js — standalone validator/prototype for the ConLogs relay decoder.
// Reassembles [[CL_CI_]] (gear/talents) and [[CL_TS_]] (positions) chunks out of an
// uploaded WoWCombatLog.txt, base64-decodes, and parses them. This is the logic that
// will move into the epoglogs server ingest; kept standalone so it can be tested
// directly against a real log with no server/DB.
//
// Usage:  node decode-relay.js "C:\path\to\WoWCombatLog.txt"

const fs = require('fs');

const path = process.argv[2];
if (!path) { console.error('usage: node decode-relay.js <combatlog.txt>'); process.exit(1); }
const text = fs.readFileSync(path, 'latin1');

// Match either family. Groups: kind, session, id(guid for CI / snapId for TS), seq, total, b64
const RE = /\[\[CL_(CI|TS)_v1_([^_]+)_([^_]+)_(\d+)\/(\d+)\]\]([A-Za-z0-9+/=]+)/g;

const ci = {}; // key `${session}_${guid}` -> { total, parts:{seq:b64} }
const ts = {}; // key `${session}_${snapId}` -> { total, parts:{seq:b64} }

let m, lines = text.split(/\r?\n/), matched = 0;
for (const line of lines) {
    RE.lastIndex = 0;
    while ((m = RE.exec(line))) {
        matched++;
        const [, kind, session, id, seqS, totalS, b64] = m;
        const bucket = kind === 'CI' ? ci : ts;
        const key = `${session}_${id}`;
        const rec = bucket[key] || (bucket[key] = { session, id, total: +totalS, parts: {} });
        rec.parts[+seqS] = b64; // dedupe: identical re-sends overwrite harmlessly
    }
}

function reassemble(rec) {
    const out = [];
    for (let i = 1; i <= rec.total; i++) {
        if (!rec.parts[i]) return null; // incomplete set
        out.push(rec.parts[i]);
    }
    return Buffer.from(out.join(''), 'base64').toString('latin1');
}

// ---- CI (gear/talents) — the ^-delimited BuildPayload wire format ----
// 1 v 2 name 3 realm 4 classFile 5 level 6 guid 7-9 spec 10 scanTime 11 zone
// 12-30 gear[19] 31 groupKey 32-34 tabNames 35-37 tabIcons 38 dbSize 39 mainName
// 40 itemInfoHints 41 talentRanks 42 senderGuild 43 charStats
function parseCI(raw) {
    const f = raw.split('^');
    const gear = f.slice(11, 30).filter(s => s && s !== '0');
    return {
        name: f[1], realm: f[2], class: f[3], level: f[4], guid: f[5],
        spec: [f[6], f[7], f[8]].join('/'),
        gearItems: gear.length,
        hasTalentRanks: !!(f[40] && f[40].length),
        hasCharStats: !!(f[42] && f[42].length),
        firstItem: gear[0] || '',
    };
}

// ---- TS (positions) — TS|getTimeMs|unixSec|mapFile|level|guid:x,y|... ----
function parseTS(raw) {
    const f = raw.split('|');
    if (f[0] !== 'TS') return null;
    const entries = f.slice(5).map(e => {
        const [g, xy] = e.split(':'); const [x, y] = (xy || '').split(',');
        return { guid: g, x: +x, y: +y };
    });
    return { tMs: +f[1], unix: +f[2], map: f[3], level: +f[4], n: entries.length, entries };
}

console.log(`\nmatched ${matched} chunk lines; CI sets=${Object.keys(ci).length} TS sets=${Object.keys(ts).length}\n`);

console.log('=== GEAR / TALENTS (CI) ===');
let ciOk = 0, ciBad = 0;
const classMap = {}, names = {};   // keyed by short guid (matches TS entries)
for (const key of Object.keys(ci)) {
    const raw = reassemble(ci[key]);
    if (!raw) { ciBad++; console.log(`  [incomplete] ${key} (have ${Object.keys(ci[key].parts).length}/${ci[key].total})`); continue; }
    try {
        const p = parseCI(raw);
        ciOk++;
        classMap[ci[key].id] = (p.class || '').toUpperCase();
        names[ci[key].id] = p.name || ci[key].id;
        console.log(`  ${p.name || '?'}  ${p.class || '?'} L${p.level || '?'}  spec=${p.spec}  gear=${p.gearItems}/19  talents=${p.hasTalentRanks} stats=${p.hasCharStats}`);
    } catch (e) { ciBad++; console.log(`  [parse error] ${key}: ${e.message}`); }
}
console.log(`  -> ${ciOk} players decoded, ${ciBad} incomplete/failed\n`);

console.log('=== POSITIONS (TS) ===');
const maps = {};
let tsOk = 0, tsBad = 0;
const snaps = [];
for (const key of Object.keys(ts)) {
    const raw = reassemble(ts[key]);
    if (!raw) { tsBad++; continue; }
    const p = parseTS(raw);
    if (!p) { tsBad++; continue; }
    tsOk++; snaps.push(p);
    maps[p.map] = (maps[p.map] || 0) + 1;
}
snaps.sort((a, b) => a.tMs - b.tMs);
console.log(`  ${tsOk} snapshots decoded (${tsBad} incomplete/failed)`);
console.log(`  maps seen: ${JSON.stringify(maps)}`);
if (snaps.length) {
    const first = snaps[0], last = snaps[snaps.length - 1];
    console.log(`  span: ${((last.tMs - first.tMs) / 1000).toFixed(1)}s, ~${first.n} units/snapshot`);
    console.log(`  sample (first snapshot, map=${first.map} lvl=${first.level}):`);
    first.entries.slice(0, 5).forEach(e => console.log(`    ${e.guid}  (${e.x}, ${e.y})`));
}
console.log('');

// ---- optional: write track.js for replay.html  (node decode-relay.js <log> track.js) ----
const jsOut = process.argv[3];
if (jsOut) {
    if (!snaps.length) { console.log(`(no positions decoded — not writing ${jsOut})`); }
    else {
        const t0ms = snaps[0].tMs;
        const mapCount = {};
        snaps.forEach(s => { mapCount[s.map] = (mapCount[s.map] || 0) + 1; });
        const map = Object.keys(mapCount).sort((a, b) => mapCount[b] - mapCount[a])[0] || 'WarsongGulch';
        const track = {
            map,
            classMap,
            names,
            snapshots: snaps.map(s => ({ t: s.tMs - t0ms, units: s.entries.map(e => ({ g: e.guid, x: e.x, y: e.y })) })),
        };
        fs.writeFileSync(jsOut, 'window.TRACK = ' + JSON.stringify(track) + ';\n');
        console.log(`wrote ${jsOut}  (map=${map}, ${track.snapshots.length} snapshots, ${Object.keys(classMap).length} players classed)`);
    }
}
