#!/usr/bin/env python3
"""Turn a hard LC_LOAD_DYLIB into LC_LOAD_WEAK_DYLIB, in place.

Used to cut the seller's injected frameworks (@rpath/PxExt*) out of a binary we
did not build. The command is rewritten, never removed: every LC_LOAD_* command
consumes one entry in the library ordinal table, and dyld's bind opcodes refer
to libraries by that ordinal. Deleting a command shifts every later ordinal by
one and silently points a few thousand binds at the wrong images.

A weak dylib that is missing is skipped, and binds against it resolve to NULL.
The file is not needed at all when nothing in the host actually calls into it.

Usage:
    python tools/defuse_seller.py --binary in --match PxExt --out out
"""

import argparse
import struct

LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--binary', required=True)
    ap.add_argument('--match', action='append', required=True,
                    help='substring of the install path to weaken')
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    d = bytearray(open(args.binary, 'rb').read())
    ncmds, sizeofcmds = struct.unpack_from('<II', d, 16)

    off = 32
    hits = []
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', d, off)
        if cmd == LC_LOAD_DYLIB:
            name_off = struct.unpack_from('<I', d, off + 8)[0]
            name = d[off + name_off:off + cs].split(b'\0')[0].decode('utf-8', 'replace')
            if any(m in name for m in args.match):
                struct.pack_into('<I', d, off, LC_LOAD_WEAK_DYLIB)
                hits.append((off, name))
        off += cs

    if not hits:
        raise SystemExit('nothing matched %s' % args.match)

    open(args.out, 'wb').write(d)
    print('ncmds %d, sizeofcmds %d' % (ncmds, sizeofcmds))
    for cmdoff, name in hits:
        print('  %#06x  LC_LOAD_DYLIB -> LC_LOAD_WEAK_DYLIB  %s' % (cmdoff, name))
    print('wrote %s (%d B)' % (args.out, len(d)))


if __name__ == '__main__':
    main()
