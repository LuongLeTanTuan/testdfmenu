import struct
import sys
import subprocess

p = sys.argv[1]
d = open(p, 'rb').read()
ncmds, size = struct.unpack_from('<II', d, 16)
print('ncmds=%d sizeofcmds=%d file=%d' % (ncmds, size, len(d)))

off = 32
seg = None
main = None
for _ in range(ncmds):
    cmd, cs = struct.unpack_from('<II', d, off)
    if cmd == 0x19:
        name = d[off + 8:off + 24].split(b'\0')[0].decode()
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', d, off + 24)
        maxp, initp = struct.unpack_from('<ii', d, off + 56)
        if name == '__PXLOAD':
            seg = (vmaddr, vmsize, fileoff, filesize, maxp, initp, off)
    elif cmd == 0x80000028:
        main = struct.unpack_from('<QQ', d, off + 8)
    off += cs
print('walk end %#x' % off)
print('LC_MAIN entryoff=%#x stack=%#x' % main)
if not seg:
    raise SystemExit('no __PXLOAD')
vmaddr, vmsize, fileoff, filesize, maxp, initp, lcoff = seg
print('__PXLOAD vm=%#x size=%#x file=%#x size=%#x maxprot=%o initprot=%o lc@%#x'
      % (vmaddr, vmsize, fileoff, filesize, maxp, initp, lcoff))
print('entry in segment: %s' % ('yes' if fileoff <= main[0] < fileoff + filesize else 'NO'))

start = main[0]
raw = d[start:start + 480]
print('\nstub hex:')
for i in range(0, len(raw), 16):
    print('  %#08x  %s' % (start + i, raw[i:i + 16].hex()))
