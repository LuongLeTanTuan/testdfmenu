#!/usr/bin/env python3
"""Rewrite the unix mode of selected zip entries without recompressing anything.

zsign writes injected dylibs with external_attr 0, which some installers turn
into a 0000-permission file. iOS can still open it, but not every installer
does the chmod, so the mode is normalised here.

Usage:
    python tools/fix_zip_modes.py --in a.ipa --out b.ipa --mode 0755 \
        Payload/App.app/PxMenu.dylib Payload/App.app/AnoMute.dylib
"""

import argparse
import os
import zipfile

CHUNK = 1 << 22


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--in', dest='src', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--mode', default='0755')
    ap.add_argument('names', nargs='+')
    args = ap.parse_args()

    mode = int(args.mode, 8) << 16
    want = set(args.names)
    seen = set()

    src = zipfile.ZipFile(args.src)
    with zipfile.ZipFile(args.out, 'w', zipfile.ZIP_DEFLATED, compresslevel=1) as dst:
        for info in src.infolist():
            zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            zi.compress_type = zipfile.ZIP_DEFLATED
            if info.filename in want:
                zi.external_attr = mode
                seen.add(info.filename)
            else:
                zi.external_attr = info.external_attr
            with src.open(info) as r, dst.open(zi, 'w') as w:
                while True:
                    b = r.read(CHUNK)
                    if not b:
                        break
                    w.write(b)

    missing = want - seen
    if missing:
        raise SystemExit('not in archive: %s' % ', '.join(sorted(missing)))
    for n in sorted(seen):
        print('mode %s  %s' % (args.mode, n))
    print('wrote %s (%d B)' % (args.out, os.path.getsize(args.out)))


if __name__ == '__main__':
    main()
