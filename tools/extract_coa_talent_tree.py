import sys, json, re

SV = r"C:\Private\Games\Ascension Launcher\resources\client\WTF\Account\DEFCON\SavedVariables\ConLogs-CoA.lua"
OUT = r"C:\Dev\wow\ConLogsApp\tools\coa_talent_tree.json"

txt = open(SV, encoding='utf-8', errors='replace').read()

# --- locate the ConLogsTalentTreeDB = { ... } assignment and slice its table ---
start = txt.index('ConLogsTalentTreeDB = {')
i = txt.index('{', start)

# Minimal recursive-descent parser for the WoW-SavedVariables Lua subset.
class P:
    def __init__(self, s, pos):
        self.s = s; self.n = len(s); self.i = pos
    def err(self, m):
        raise ValueError(f"{m} at {self.i}: ...{self.s[self.i:self.i+40]!r}")
    def ws(self):
        s, n = self.s, self.n
        while self.i < n:
            c = s[self.i]
            if c in ' \t\r\n':
                self.i += 1
            elif c == '-' and self.i + 1 < n and s[self.i+1] == '-':
                # line comment to end of line
                j = s.find('\n', self.i)
                self.i = n if j == -1 else j + 1
            else:
                break
    def value(self):
        self.ws()
        c = self.s[self.i]
        if c == '{': return self.table()
        if c == '"': return self.string()
        return self.scalar()
    def string(self):
        s = self.s; i = self.i + 1; out = []
        while i < self.n:
            c = s[i]
            if c == '\\':
                nx = s[i+1]
                out.append({'n':'\n','t':'\t','r':'\r','"':'"','\\':'\\'}.get(nx, nx))
                i += 2
            elif c == '"':
                self.i = i + 1
                return ''.join(out)
            else:
                out.append(c); i += 1
        self.err("unterminated string")
    def scalar(self):
        s = self.s; j = self.i
        while j < self.n and s[j] not in ',}]\r\n \t':
            j += 1
        tok = s[self.i:j]; self.i = j
        if tok == 'true': return True
        if tok == 'false': return False
        if tok == 'nil': return None
        try:
            return int(tok)
        except ValueError:
            try: return float(tok)
            except ValueError: return tok
    def key(self):
        # expects [ "str" | number ]
        self.ws()
        assert self.s[self.i] == '['
        self.i += 1; self.ws()
        if self.s[self.i] == '"':
            k = self.string()
        else:
            k = self.scalar()
        self.ws()
        assert self.s[self.i] == ']', self.err("expected ]")
        self.i += 1; self.ws()
        assert self.s[self.i] == '=', self.err("expected =")
        self.i += 1
        return k
    def table(self):
        assert self.s[self.i] == '{'
        self.i += 1
        d = {}; lst = []
        while True:
            self.ws()
            c = self.s[self.i]
            if c == '}':
                self.i += 1; break
            if c == ',':
                self.i += 1; continue
            if c == '[':
                k = self.key(); d[k] = self.value()
            else:
                lst.append(self.value())
        if d and not lst: return d
        if lst and not d: return lst
        if not d and not lst: return []   # empty Lua tables are array-typed here (requires/spells)
        # mixed: fold list into dict under 1-based indices
        for idx, v in enumerate(lst, 1): d[idx] = v
        return d

p = P(txt, i)
tree = p.table()
export = tree.get('coaExport')
if export is None:
    print("coaExport NOT found in ConLogsTalentTreeDB"); sys.exit(1)

nodes = export.get('nodes', [])
# also collect classes for the geomancy check
classes = sorted({n.get('class') for n in nodes if isinstance(n, dict) and n.get('class')})

payload = {
    "version": export.get("version"),
    "capturedAt": export.get("capturedAt"),
    "locale": export.get("locale"),
    "count": export.get("count"),
    "nodes": nodes,
}
json.dump(payload, open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'))

import os
def has(n, k): return isinstance(n.get(k), (int, float)) and n.get(k) is not None
with_req = sum(1 for n in nodes if n.get('requires'))
with_xy  = sum(1 for n in nodes if n.get('x') or n.get('y'))
with_grid= sum(1 for n in nodes if n.get('col') or n.get('row'))
JUNK_TAB = {'None', 'INVALID_TAB_TYPE_0', 'party'}
JUNK_CLS = {'None', 'party'}
junk = sum(1 for n in nodes if n.get('tab') in JUNK_TAB or n.get('class') in JUNK_CLS)
print(f"wrote {OUT}  ({os.path.getsize(OUT):,} bytes)")
print(f"nodes: {len(nodes)}  | with prereq links: {with_req}  | with xy pos: {with_xy}  | with grid pos: {with_grid}  | junk (filterable): {junk}")
print(f"classes ({len(classes)}): {', '.join(classes)}")
print("Wildwalker/geomancy present:", "Wildwalker" in classes or "Primalist" in classes)
