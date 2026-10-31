#!/usr/bin/env python3
"""Check the Mach-O invariants that decide whether iOS will exec the binary.

Everything here is a rule the kernel, dyld or ldid enforces. A failure means the
process is killed before any of our code runs, which is exactly the shape of a
crash with no log and no process.
"""

import struct
import sys

PAGE = 0x4000
SEG = 0x19
SEG64_CMDSIZE = 72

# load commands whose payload is addressed by file offset into __LINKEDIT
LE_DATA_CMDS = {0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x80000033, 0x80000034}


def main():
    path = sys.argv[1]
    d = open(path, 'rb').read()
    problems = []

    ncmds, sizeofcmds = struct.unpack_from('<II', d, 16)
    print('file       : %s (%d B)' % (path, len(d)))
    print('ncmds      : %d, sizeofcmds %d' % (ncmds, sizeofcmds))

    segs = []
    sections = []
    main_cmd = None
    le_refs = []
    off = 32
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', d, off)
        if cs < 8 or off + cs > 32 + sizeofcmds:
            problems.append('load command at %#x has bad cmdsize %d' % (off, cs))
            break
        if cmd == SEG:
            name = d[off + 8:off + 24].split(b'\0')[0].decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', d, off + 24)
            nsects = struct.unpack_from('<I', d, off + 64)[0]
            segs.append((name, vmaddr, vmsize, fileoff, filesize))
            for s in range(nsects):
                so = off + 72 + s * 80
                sect = d[so:so + 16].split(b'\0')[0].decode()
                saddr = struct.unpack_from('<Q', d, so + 32)[0]
                ssize = struct.unpack_from('<Q', d, so + 40)[0]
                soff = struct.unpack_from('<I', d, so + 48)[0]
                sections.append((name, sect, saddr, ssize, soff))
        elif cmd == 0x80000028:
            main_cmd = struct.unpack_from('<QQ', d, off + 8)
        elif cmd in LE_DATA_CMDS:
            le_refs.append((hex(cmd), off, struct.unpack_from('<I', d, off + 8)[0]))
        elif cmd in (0x22, 0x80000022):
            for k in range(5):
                v = struct.unpack_from('<I', d, off + 8 + k * 8)[0]
                if v:
                    le_refs.append(('dyld_info%d' % k, off, v))
        elif cmd == 0x2:
            le_refs.append(('symoff', off, struct.unpack_from('<I', d, off + 8)[0]))
            le_refs.append(('stroff', off, struct.unpack_from('<I', d, off + 16)[0]))
        elif cmd == 0xB:
            for idx in (6, 8, 10, 12, 14, 16):
                v = struct.unpack_from('<I', d, off + 8 + idx * 4)[0]
                if v:
                    le_refs.append(('dysym%d' % idx, off, v))
        elif cmd == 0x2C:      # LC_ENCRYPTION_INFO_64
            cryptoff, cryptsize, cryptid = struct.unpack_from('<III', d, off + 8)
            print('crypt      : off %#x size %#x id %d' % (cryptoff, cryptsize, cryptid))
            if cryptid:
                problems.append('binary is still encrypted')
        off += cs

    print('walk end   : %#x' % off)
    if off != 32 + sizeofcmds:
        problems.append('sizeofcmds does not reach the end of the command list')

    for name, vmaddr, vmsize, fileoff, filesize in segs:
        print('seg %-11s vm %#011x + %#010x  file %#010x + %#010x'
              % (name, vmaddr, vmsize, fileoff, filesize))

    # 1. segments must be sorted by vmaddr and must not overlap
    for a, b in zip(segs, segs[1:]):
        if a[1] >= b[1]:
            problems.append('segments not sorted: %s before %s' % (a[0], b[0]))
        if a[1] + a[2] > b[1]:
            problems.append('vm overlap: %s ends %#x, %s starts %#x'
                            % (a[0], a[1] + a[2], b[0], b[1]))
        if a[3] < b[3] and a[3] + a[4] > b[3]:
            problems.append('file overlap: %s ends %#x, %s starts %#x'
                            % (a[0], a[3] + a[4], b[0], b[3]))

    linkedit = [s for s in segs if s[0] == '__LINKEDIT']
    if not linkedit:
        problems.append('no __LINKEDIT')
    else:
        le = linkedit[0]
        if segs[-1][0] != '__LINKEDIT':
            problems.append('__LINKEDIT is not the last segment (%s is)' % segs[-1][0])
        if le[3] + le[4] != len(d):
            problems.append('__LINKEDIT does not end at EOF: %#x != %#x'
                            % (le[3] + le[4], len(d)))
        for tag, cmdoff, v in le_refs:
            if not (le[3] <= v < len(d)):
                problems.append('%s at %#x points outside __LINKEDIT: %#x' % (tag, cmdoff, v))

    if main_cmd is None:
        problems.append('no LC_MAIN')
    else:
        entryoff = main_cmd[0]
        text = [s for s in segs if s[0] == '__TEXT'][0]
        where = None
        for name, vmaddr, vmsize, fileoff, filesize in segs:
            if fileoff <= entryoff < fileoff + filesize:
                where = name
        print('LC_MAIN    : entryoff %#x, lands in %s, vaddr %#x'
              % (entryoff, where, text[1] + entryoff))
        if where != '__TEXT':
            problems.append('entryoff %#x does not land inside __TEXT' % entryoff)
        if not (text[3] <= entryoff < text[3] + text[4]):
            problems.append('entryoff outside __TEXT file range')

        # entry must be inside an executable section, not in __text itself
        for segname, sect, saddr, ssize, soff in sections:
            if sect == '__text':
                if soff <= entryoff < soff + ssize:
                    problems.append('entryoff %#x lands inside __text' % entryoff)
                print('__text     : file %#x, %d B; stub window %#x-%#x'
                      % (soff, ssize, soff - 0x800, soff))

    print()
    if problems:
        print('FAIL (%d)' % len(problems))
        for p in problems:
            print('  - %s' % p)
        raise SystemExit(1)
    print('PASS: segments sorted, __LINKEDIT last and ending at EOF,'
          ' every linkedit offset inside it, entry inside __TEXT')


if __name__ == '__main__':
    main()
