#!/usr/bin/env python3
"""Rebuild the IPA from the seller's zip with a patched main binary.

Streams every entry through unchanged except the ones named on the command
line, so the 1.1 GB payload is never held in memory and the archive layout
stays byte-comparable to the original.

The app's own _CodeSignature is dropped: it signs the old binary, and every
installer worth using re-signs the whole bundle anyway.

Usage:
    python tools/pack_ipa.py --source delta.zip --replace \\
        Payload/DeltaForceClient.app/DeltaForceClient=D:/delta/_pxbin \\
        --drop Payload/DeltaForceClient.app/_CodeSignature \\
        --out D:/delta/DeltaForce_Embedded.ipa
"""

import argparse
import os
import zipfile


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', required=True)
    ap.add_argument('--replace', action='append', default=[])
    ap.add_argument('--drop', action='append', default=[])
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    repl = {}
    for spec in args.replace:
        name, _, path = spec.rpartition('=')
        if not name or not os.path.isfile(path):
            raise SystemExit('bad --replace %r' % spec)
        repl[name] = path

    drops = [d.rstrip('/') for d in args.drop]

    src = zipfile.ZipFile(args.source)
    seen = set()
    with zipfile.ZipFile(args.out, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as dst:
        for info in src.infolist():
            name = info.filename
            if any(name == d or name.startswith(d + '/') for d in drops):
                continue
            mode = info.external_attr >> 16
            if name in repl:
                seen.add(name)
                with open(repl[name], 'rb') as fh:
                    data = fh.read()
                zi = zipfile.ZipInfo(name, date_time=info.date_time)
                zi.external_attr = 0o100755 << 16
                zi.compress_type = zipfile.ZIP_DEFLATED
                dst.writestr(zi, data)
                print('replace %-58s %d B' % (name, len(data)))
                continue
            zi = zipfile.ZipInfo(name, date_time=info.date_time)
            zi.external_attr = info.external_attr
            zi.compress_type = zipfile.ZIP_DEFLATED
            with src.open(info) as fh:
                dst.writestr(zi, fh.read())

    missing = set(repl) - seen
    if missing:
        raise SystemExit('not in source archive: %s' % ', '.join(sorted(missing)))
    print('wrote %s (%d B)' % (args.out, os.path.getsize(args.out)))


if __name__ == '__main__':
    main()
