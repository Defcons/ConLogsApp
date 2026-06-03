import glob, os, mpyq

DATA = r"C:\Private\Games\Ascension Launcher\resources\epoch_live\Data"
MPQS = glob.glob(os.path.join(DATA, "*.MPQ")) + glob.glob(os.path.join(DATA, "enUS", "*.MPQ"))

targets = ["warsonggulch", "naxxramas", "dustwallow"]
seen = {t: set() for t in targets}

for m in MPQS:
    try:
        a = mpyq.MPQArchive(m, listfile=True)
        files = a.files or []
    except Exception:
        continue
    for f in files:
        low = f.lower()
        if b"worldmap" in low:
            for t in targets:
                if b"\\" + t.encode() + b"\\" in low.replace(b"/", b"\\"):
                    seen[t].add(f.decode("latin1"))

for t in targets:
    print("=== %s (%d files) ===" % (t, len(seen[t])))
    for f in sorted(seen[t])[:20]:
        print("  ", f)
    print()
