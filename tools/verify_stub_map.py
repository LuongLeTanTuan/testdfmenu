import struct
import sys

p = sys.argv[1] if len(sys.argv) > 1 else r'D:\delta\_pxbin'
d = open(p, 'rb').read()
ncmds = struct.unpack_from('<I', d, 16)[0]
off = 32
symtab = dys = None
sections = []
for _ in range(ncmds):
    cmd, cs = struct.unpack_from('<II', d, off)
    if cmd == 0x19:
        segname = d[off + 8:off + 24].split(b'\0')[0].decode()
        nsects = struct.unpack_from('<I', d, off + 64)[0]
        for s in range(nsects):
            so = off + 72 + s * 80
            sect = d[so:so + 16].split(b'\0')[0].decode()
            seg = d[so + 16:so + 32].split(b'\0')[0].decode()
            addr, size = struct.unpack_from('<QQ', d, so + 32)
            fo, _, _, _, flags = struct.unpack_from('<IIIII', d, so + 48)
            r1 = struct.unpack_from('<I', d, so + 68)[0]
            sections.append((seg, sect, addr, size, fo, flags, r1))
    elif cmd == 0x2:
        symtab = struct.unpack_from('<IIII', d, off + 8)
    elif cmd == 0xB:
        dys = struct.unpack_from('<IIIIIIIIIIIIIIIIIIII', d, off + 8)
    off += cs

symoff, nsyms, stroff, strsize = symtab
ind_off, n_ind = dys[12], dys[13]


def sym_name(idx):
    if idx >= nsyms:
        return None
    strx = struct.unpack_from('<I', d, symoff + idx * 16)[0]
    if strx >= strsize:
        return None
    e = d.index(b'\0', stroff + strx)
    return d[stroff + strx:e].decode('utf-8', 'replace')


def name_for_stub(va):
    stub = [s for s in sections if s[0] == '__TEXT' and s[1] == '__stubs'][0]
    fo = stub[4] + (va - stub[2])
    w0, w1, w2 = struct.unpack_from('<III', d, fo)
    immlo = (w0 >> 29) & 3
    immhi = (w0 >> 5) & 0x7FFFF
    imm = (immhi << 2) | immlo
    if imm & (1 << 20):
        imm -= 1 << 21
    slot = (va & ~0xFFF) + (imm << 12) + ((w1 >> 10) & 0xFFF) * 8
    for sec in sections:
        if (sec[5] & 0xFF) not in (6, 7):
            continue
        if not (sec[2] <= slot < sec[2] + sec[3]):
            continue
        idx = sec[6] + (slot - sec[2]) // 8
        if idx >= n_ind:
            return None
        si = struct.unpack_from('<I', d, ind_off + idx * 4)[0]
        if si & 0xC0000000:
            return None
        return sec[1], hex(slot), sym_name(si)
    return 'out-of-range', hex(slot)


stub_base = [s for s in sections if s[0] == '__TEXT' and s[1] == '__stubs'][0][2]
targets = sys.argv[2:] or ['0x110d056bc', '0x110d06070', '0x110d0718c',
                           '0x110d05140', '0x110d05428', '0x110d07024']
for t in targets:
    va = int(t, 16)
    got = name_for_stub(va)
    print(t, '->', repr(got))
