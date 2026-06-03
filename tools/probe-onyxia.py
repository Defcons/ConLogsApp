import glob, os, mpyq

DATA = r"C:\Private\Games\Ascension Launcher\resources\epoch_live\Data"
mpqs = glob.glob(os.path.join(DATA, "*.MPQ")) + glob.glob(os.path.join(DATA, "enUS", "*.MPQ"))

# Candidate WorldMap directory names for a (possibly custom) Onyxia's Lair.
dirs = [
    "Onyxia", "OnyxiasLair", "OnyxiaLair", "OnyxiaLairUI", "Onyxias",
    "OnyxiaLairClassic", "OnyxiasLairClassic", "OnyxiaClassic", "OnyxiaLair40",
    "Onyxia40", "OnyxiaLairEntrance", "DustwallowMarsh", "Dustwallow",
]

def candidates():
    for d in dirs:
        yield "Interface\\WorldMap\\%s\\%s1.blp" % (d, d)   # first tile
        yield "Interface\\WorldMap\\%s\\%s.blp" % (d, d)     # single-image variant

found = []
for m in mpqs:
    name = os.path.basename(m)
    try:
        a = mpyq.MPQArchive(m, listfile=False)
    except Exception as e:
        print("open ERR", name, e); continue
    for path in candidates():
        try:
            data = a.read_file(path)
        except Exception:
            data = None
        if data:
            print("HIT", name, "::", path, "(%d bytes)" % len(data))
            found.append((name, path))

if not found:
    print("no Onyxia WorldMap tile found by candidate-name probe across", len(mpqs), "MPQs")
    print("(custom name unknown — tonight's GetMapInfo() will give the exact dir)")
