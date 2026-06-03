import glob, os, mpyq

DATA = r"C:\Private\Games\Ascension Launcher\resources\epoch_live\Data"
mpqs = glob.glob(os.path.join(DATA, "*.MPQ")) + glob.glob(os.path.join(DATA, "enUS", "*.MPQ"))

onyxia_hits = []
worldmap_dirs = set()

for m in mpqs:
    try:
        a = mpyq.MPQArchive(m, listfile=True)
        files = a.files or []
    except Exception as e:
        print("ERR", os.path.basename(m), e)
        continue
    for f in files:
        low = f.lower()
        if b"worldmap" in low:
            # collect the worldmap subdir name
            parts = f.replace(b"/", b"\\").split(b"\\")
            try:
                wi = [p.lower() for p in parts].index(b"worldmap")
                if wi + 1 < len(parts):
                    worldmap_dirs.add(parts[wi + 1].decode("latin1"))
            except ValueError:
                pass
            if b"onyxia" in low:
                onyxia_hits.append((os.path.basename(m), f.decode("latin1")))

print("=== Onyxia WorldMap files ===")
for mm, ff in onyxia_hits:
    print(" ", mm, "::", ff)
if not onyxia_hits:
    print("  (none found by 'onyxia' — listing all WorldMap dirs to identify it)")
    for d in sorted(worldmap_dirs):
        if "ony" in d.lower() or "lair" in d.lower():
            print("  candidate:", d)
    print("  --- all worldmap dirs (%d) ---" % len(worldmap_dirs))
    print("  " + ", ".join(sorted(worldmap_dirs)))
