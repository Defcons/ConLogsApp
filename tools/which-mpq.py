import glob, os, mpyq

DATA = r"C:\Private\Games\Ascension Launcher\resources\epoch_live\Data"
MPQS = glob.glob(os.path.join(DATA, "*.MPQ")) + glob.glob(os.path.join(DATA, "enUS", "*.MPQ"))

path = "Interface\\WorldMap\\NetherstormArena\\NetherstormArena1.blp"
print("which MPQs contain", path)
for m in MPQS:
    try:
        a = mpyq.MPQArchive(m, listfile=False)
        d = a.read_file(path)
    except Exception as e:
        d = None
    if d:
        print("  %-22s %d bytes" % (os.path.basename(m), len(d)))
