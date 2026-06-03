import glob, os, struct, mpyq

DATA = r"C:\Private\Games\Ascension Launcher\resources\epoch_live\Data"
MPQS = glob.glob(os.path.join(DATA, "*.MPQ")) + glob.glob(os.path.join(DATA, "enUS", "*.MPQ"))

def find_tile(name, idx):
    path = "Interface\\WorldMap\\%s\\%s%d.blp" % (name, name, idx)
    for m in MPQS:
        try:
            a = mpyq.MPQArchive(m, listfile=False)
            d = a.read_file(path)
        except Exception:
            d = None
        if d:
            return d, os.path.basename(m), path
    return None, None, path

for name in ("WarsongGulch",):
    # how many tiles?
    count = 0
    for i in range(1, 17):
        d, mpq, path = find_tile(name, i)
        if not d:
            break
        count += 1
        if i == 1:
            assert d[:4] == b"BLP2", d[:4]
            typ, = struct.unpack_from("<I", d, 4)
            enc, alphaDepth, alphaEnc, hasMips = struct.unpack_from("<BBBB", d, 8)
            w, h = struct.unpack_from("<II", d, 12)
            print("%s tile1 from %s" % (name, mpq))
            print("  type=%d encoding=%d alphaDepth=%d alphaEnc=%d hasMips=%d size=%dx%d bytes=%d"
                  % (typ, enc, alphaDepth, alphaEnc, hasMips, w, h, len(d)))
    print("  %s: %d tiles present" % (name, count))
