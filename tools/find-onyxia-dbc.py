import glob, os, struct, mpyq

DATA = r"C:\Private\Games\Ascension Launcher\resources\epoch_live\Data"
MPQS = glob.glob(os.path.join(DATA, "*.MPQ")) + glob.glob(os.path.join(DATA, "enUS", "*.MPQ"))

def get_dbc(path):
    out = []
    for m in MPQS:
        try:
            a = mpyq.MPQArchive(m, listfile=False)
            d = a.read_file(path)
            if d:
                out.append((os.path.basename(m), d))
        except Exception:
            pass
    return out

def parse(data):
    if data[:4] != b"WDBC":
        return None
    rc, fc, rs, sbs = struct.unpack_from("<4I", data, 4)
    rec0 = 20
    sb = data[rec0 + rc * rs: rec0 + rc * rs + sbs]
    def s(off):
        e = sb.find(b"\0", off)
        return sb[off:e].decode("latin1", "replace")
    rows = []
    for i in range(rc):
        f = struct.unpack_from("<%dI" % fc, data, rec0 + i * rs)
        rows.append(f, )
        rows[-1] = f
    return rc, fc, rs, rows, s

# WorldMapArea.dbc (3.3.5): [0]ID [1]mapID [2]areaID [3]AreaName(strOff) [4..7]loc...
for mpqname, d in get_dbc("DBFilesClient\\WorldMapArea.dbc"):
    parsed = parse(d)
    if not parsed:
        print(mpqname, "not WDBC"); continue
    rc, fc, rs, rows, s = parsed
    names = sorted({s(f[3]) for f in rows if f[3] < 10**7})
    print("=== %s  (records=%d fields=%d, %d names) ===" % (mpqname, rc, fc, len(names)))
    for probe in ("onyxia", "warsong", "naxx", "dustwallow"):
        hits = [n for n in names if probe in n.lower()]
        print("   %-10s -> %s" % (probe, hits if hits else "(none)"))
    print("   all:", ", ".join(names))
