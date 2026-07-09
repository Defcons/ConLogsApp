#!/usr/bin/env python3
"""Build a public release zip for a ConLogs addon.

Produces the distributable zip from an addon source dir, applying the two
release-only transforms (dev source keeps everything; only the zip is stripped):

  1. Drop the ConLogsSpike module  — exclude ConLogsSpike.lua from the load list
     and remove ConLogsSpikeDB from the .toc ## SavedVariables line.
  2. Strip developer/diagnostic slash commands — remove every block between
     `--@strip-dev-begin@` and `--@strip-dev-end@` (inclusive) from each .lua.
     (dump / dumpspec / dumpstats / dumpentries — see the slash handler.)

Usage:  python build_release.py <addon_src_dir> <out_zip_path>
The zip's top-level folder is the addon dir's basename (its AddOns folder name).
"""
import os, sys, re, glob, shutil, zipfile

def strip_dev(text):
    out, skipping = [], False
    for line in text.splitlines(keepends=True):
        if "@strip-dev-begin@" in line:
            skipping = True; continue
        if "@strip-dev-end@" in line:
            skipping = False; continue
        if not skipping:
            out.append(line)
    if skipping:
        raise SystemExit("ERROR: unterminated @strip-dev-begin@ (missing @strip-dev-end@)")
    return "".join(out)

def build(src, out_zip):
    src = os.path.abspath(src)
    name = os.path.basename(src.rstrip("\\/"))
    toc_path = glob.glob(os.path.join(src, "*.toc"))
    if not toc_path:
        raise SystemExit(f"no .toc in {src}")
    toc_path = toc_path[0]

    stage = out_zip + ".stage"
    pkg = os.path.join(stage, name)
    if os.path.isdir(stage): shutil.rmtree(stage)
    os.makedirs(pkg)

    toc_lines, load_files = [], []
    for line in open(toc_path, encoding="utf-8").read().splitlines():
        s = line.strip()
        if s == "ConLogsSpike.lua":
            continue                                   # drop Spike from load order
        if line.startswith("## SavedVariables:"):
            line = re.sub(r",\s*ConLogsSpikeDB", "", line)
        if re.match(r"^[\w\-]+\.(lua|xml)$", s):
            load_files.append(s)
        toc_lines.append(line)
    open(os.path.join(pkg, os.path.basename(toc_path)), "w",
         encoding="utf-8", newline="\n").write("\n".join(toc_lines) + "\n")

    for f in load_files:
        data = open(os.path.join(src, f), encoding="utf-8").read()
        if f.endswith(".lua"):
            data = strip_dev(data)
        open(os.path.join(pkg, f), "w", encoding="utf-8", newline="\n").write(data)

    if os.path.exists(out_zip): os.remove(out_zip)
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(pkg):
            for fn in files:
                fp = os.path.join(root, fn)
                z.write(fp, os.path.relpath(fp, stage))
    shutil.rmtree(stage)
    print(f"built {out_zip} ({os.path.getsize(out_zip)} bytes) — folder '{name}', {len(load_files)} files")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    build(sys.argv[1], sys.argv[2])
