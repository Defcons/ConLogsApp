#!/usr/bin/env python
# extract-map.py <MapDir> [dungeonLevel]
# Pulls the 12 WorldMap tiles for a zone out of the Epoch MPQs, decodes the BLP2/DXT
# tiles, and stitches them into one background PNG (4 cols x 3 rows = 1024x768).
#
#   single-level zones:  <Name><tile>.blp           (tile 1..12)
#   multi-level dungeons: <Name><level>_<tile>.blp   (e.g. Naxxramas1_1.blp)
#
# Player coords from GetPlayerMapPosition are 0..1; the usable map area is the
# top-left 1002x668 of the stitched 1024x768 image (standard WoW WorldMap layout).

import sys, os, glob, re, struct, mpyq
from PIL import Image

DATA = r"C:\Private\Games\Ascension Launcher\resources\epoch_live\Data"
MPQS = glob.glob(os.path.join(DATA, "*.MPQ")) + glob.glob(os.path.join(DATA, "enUS", "*.MPQ"))

# Patch-override priority: custom letter-patches (patch-A..Z) win over numbered
# patches, which win over base/locale. Higher = tried first, so a reskinned map
# (e.g. Gillijim's Isle overriding NetherstormArena) beats the stock tiles.
def _prio(name):
    n = name.lower()
    m = re.match(r"patch-([a-z])\.mpq", n)
    if m: return 1000 + ord(m.group(1))
    m = re.match(r"patch-(\d+)\.mpq", n)
    if m: return 500 + int(m.group(1))
    if "patch-enus" in n: return 460
    if n == "patch.mpq": return 400
    return 100

ARCHIVES = []
for m in MPQS:
    try: ARCHIVES.append((_prio(os.path.basename(m)), mpyq.MPQArchive(m, listfile=False)))
    except Exception: pass
ARCHIVES.sort(key=lambda t: -t[0])

def read_tile(name, level, tile):
    if level:
        path = "Interface\\WorldMap\\%s\\%s%d_%d.blp" % (name, name, level, tile)
    else:
        path = "Interface\\WorldMap\\%s\\%s%d.blp" % (name, name, tile)
    for _p, a in ARCHIVES:
        try:
            d = a.read_file(path)
            if d: return d
        except Exception:
            pass
    return None

# ---- BLP2 decode (enc 1 palettized / enc 2 DXT1/3/5 / enc 3 BGRA) ----
def rgb565(c):
    return (((c >> 11) & 0x1f) * 255 // 31, ((c >> 5) & 0x3f) * 255 // 63, (c & 0x1f) * 255 // 31)

def dxt_palette(c0, c1):
    a, b = rgb565(c0), rgb565(c1)
    if c0 > c1:
        c2 = tuple((2 * a[i] + b[i]) // 3 for i in range(3))
        c3 = tuple((a[i] + 2 * b[i]) // 3 for i in range(3))
    else:
        c2 = tuple((a[i] + b[i]) // 2 for i in range(3))
        c3 = (0, 0, 0)
    return (a, b, c2, c3)

def decode_dxt(data, w, h, blocksize, coloff):
    img = Image.new("RGB", (w, h)); px = img.load()
    o = 0
    for by in range(0, h, 4):
        for bx in range(0, w, 4):
            blk = data[o:o + blocksize]; o += blocksize
            c0 = blk[coloff] | (blk[coloff + 1] << 8)
            c1 = blk[coloff + 2] | (blk[coloff + 3] << 8)
            bits = blk[coloff + 4] | (blk[coloff + 5] << 8) | (blk[coloff + 6] << 16) | (blk[coloff + 7] << 24)
            cols = dxt_palette(c0, c1)
            for py in range(4):
                for pxi in range(4):
                    if bx + pxi < w and by + py < h:
                        px[bx + pxi, by + py] = cols[(bits >> (2 * (4 * py + pxi))) & 3]
    return img

def decode_blp(data):
    assert data[:4] == b"BLP2", data[:4]
    enc, alphaDepth, alphaEnc, hasMips = struct.unpack_from("<BBBB", data, 8)
    w, h = struct.unpack_from("<II", data, 12)
    mipOff = struct.unpack_from("<16I", data, 20)
    mipSz = struct.unpack_from("<16I", data, 84)
    raw = data[mipOff[0]:mipOff[0] + mipSz[0]]
    if enc == 2:
        if alphaEnc == 0:   return decode_dxt(raw, w, h, 8, 0)    # DXT1
        else:               return decode_dxt(raw, w, h, 16, 8)   # DXT3/5 (color only)
    if enc == 1:
        pal = data[148:148 + 1024]
        out = bytearray()
        for i in range(w * h):
            b, g, r, _ = pal[raw[i] * 4:raw[i] * 4 + 4]
            out += bytes((r, g, b))
        return Image.frombytes("RGB", (w, h), bytes(out))
    if enc == 3:
        im = Image.frombytes("RGBA", (w, h), raw)
        b, g, r, a = im.split(); return Image.merge("RGB", (r, g, b))
    raise SystemExit("unhandled BLP encoding %d" % enc)

def main():
    name = sys.argv[1]
    level = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    canvas = Image.new("RGB", (1024, 768))
    found = 0
    for t in range(1, 13):
        d = read_tile(name, level, t)
        if not d:
            print("  missing tile %d" % t); continue
        tile = decode_blp(d)
        col, row = (t - 1) % 4, (t - 1) // 4
        canvas.paste(tile, (col * 256, row * 256))
        found += 1
    if not found:
        raise SystemExit("no tiles found for %s (level %s)" % (name, level))
    out = "%s%s.png" % (name, ("_lvl%d" % level) if level else "")
    outpath = os.path.join(os.path.dirname(__file__), out)
    canvas.save(outpath)
    print("wrote %s  (%d/12 tiles, 1024x768)" % (outpath, found))

if __name__ == "__main__":
    main()
