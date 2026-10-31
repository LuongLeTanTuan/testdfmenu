#!/usr/bin/env python3
"""Embed the injected dylibs inside the app's main binary.

No LC_LOAD_DYLIB, no file under Frameworks/, nothing for a bundle scan to find.
The binary grows one RX segment holding a small arm64 stub plus the dylib
bytes. LC_MAIN is retargeted at the stub; the stub writes each dylib into the
app's own tmp dir, dlopen()s it, unlinks it, then jumps to the real entry point.

The stub reaches libSystem through the host's existing __stubs table, so it
needs no bind entries of its own and nothing to relocate: every address it
touches is PC-relative inside the image and slide-correct by construction.

Usage:
    python tools/embed_payload.py --binary Path/DeltaForceClient \\
        --dylib a.dylib --dylib b.dylib --out Path/DeltaForceClient.out
"""

import argparse
import os
import struct

import keystone

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
LC_MAIN = 0x80000028

PAGE = 0x4000          # arm64 iOS page size
CODE_RESERVE = 0x800   # room for the stub; the layout depends on it, so it is fixed

# libSystem entry points the stub needs. All of these are already imported by
# the host, so their lazy stubs exist and are bound before LC_MAIN runs.
NEEDED = ['_getenv', '_open', '_write', '_close', '_dlopen', '_unlink']


def align_up(v, a):
    return (v + a - 1) & ~(a - 1)


class MachO:
    def __init__(self, data):
        self.d = data
        if struct.unpack_from('<I', data, 0)[0] != 0xFEEDFACF:
            raise SystemExit('not a thin little-endian Mach-O')
        self.ncmds, self.sizeofcmds = struct.unpack_from('<II', data, 16)
        self.segments = []
        self.sections = []
        self.symtab = None
        self.dysymtab = None
        self.main = None

        off = 32
        for _ in range(self.ncmds):
            cmd, cs = struct.unpack_from('<II', data, off)
            if cmd == LC_SEGMENT_64:
                name = data[off + 8:off + 24].split(b'\0')[0].decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', data, off + 24)
                nsects = struct.unpack_from('<I', data, off + 64)[0]
                self.segments.append((name, vmaddr, vmsize, fileoff, filesize))
                for s in range(nsects):
                    so = off + 72 + s * 80
                    sect = data[so:so + 16].split(b'\0')[0].decode()
                    seg = data[so + 16:so + 32].split(b'\0')[0].decode()
                    addr, size = struct.unpack_from('<QQ', data, so + 32)
                    fo, _, _, _, flags = struct.unpack_from('<IIIII', data, so + 48)
                    reserved1 = struct.unpack_from('<I', data, so + 68)[0]
                    self.sections.append((seg, sect, addr, size, fo, flags, reserved1))
            elif cmd == LC_SYMTAB:
                self.symtab = struct.unpack_from('<IIII', data, off + 8)
            elif cmd == LC_DYSYMTAB:
                self.dysymtab = struct.unpack_from('<IIIIIIIIIIIIIIIIIIII', data, off + 8)
            elif cmd == LC_MAIN:
                self.main = struct.unpack_from('<QQ', data, off + 8)
            off += cs
        self.header_end = off
        if not self.symtab or not self.dysymtab or not self.main:
            raise SystemExit('missing symtab/dysymtab/LC_MAIN')

    def segment(self, name):
        for seg in self.segments:
            if seg[0] == name:
                return seg
        raise SystemExit('no %s segment' % name)

    def section(self, seg, sect):
        for s in self.sections:
            if s[0] == seg and s[1] == sect:
                return s
        return None

    def symbol_name(self, idx):
        symoff, nsyms, stroff, strsize = self.symtab
        if idx >= nsyms:
            return None
        strx = struct.unpack_from('<I', self.d, symoff + idx * 16)[0]
        if strx >= strsize:
            return None
        end = self.d.index(b'\0', stroff + strx)
        return self.d[stroff + strx:end].decode('utf-8', 'replace')

    def stub_addresses(self):
        """name -> address of the host's own binding stub for it.

        The stub's indirect-symbol index is not aligned with __stubs: the last
        few entries point into __got rather than __la_symbol_ptr, and reading
        the name off __stubs' own reserved1 lands on the wrong symbol. Decode
        each stub, work out which pointer section it actually reads, and take
        the name from that section's indirect table.
        """
        stubs = self.section('__TEXT', '__stubs')
        if not stubs:
            raise SystemExit('no __TEXT,__stubs section')
        _, _, stub_addr, stub_size, stub_off, _, _ = stubs

        slots = []
        for sec in self.sections:
            kind = sec[5] & 0xFF
            if kind in (0x6, 0x7):          # NON_LAZY / LAZY symbol pointers
                slots.append(sec)

        indirect_off, n_indirect = self.dysymtab[12], self.dysymtab[13]
        out = {}
        for i in range(stub_size // 12):
            va = stub_addr + i * 12
            fo = stub_off + i * 12
            w0, w1, w2 = struct.unpack_from('<III', self.d, fo)
            if (w0 & 0x9F00001F) != 0x90000010:   # adrp x16
                continue
            if (w1 & 0xFFC00000) != 0xF9400000:   # ldr x16, [x16, #imm]
                continue
            if w2 != 0xD61F0200:                  # br x16
                continue
            immlo = (w0 >> 29) & 0x3
            immhi = (w0 >> 5) & 0x7FFFF
            imm = ((immhi << 2) | immlo)
            if imm & (1 << 20):
                imm -= 1 << 21
            page = (va & ~0xFFF) + (imm << 12)
            slot_addr = page + ((w1 >> 10) & 0xFFF) * 8

            for sec in slots:
                _, _, saddr, ssize, _, _, sres1 = sec
                if not (saddr <= slot_addr < saddr + ssize):
                    continue
                idx = sres1 + (slot_addr - saddr) // 8
                if idx >= n_indirect:
                    break
                si = struct.unpack_from('<I', self.d, indirect_off + idx * 4)[0]
                if si & 0xC0000000:
                    break
                name = self.symbol_name(si)
                if name and name not in out:
                    out[name] = va
                break
        return out


class Assembler:
    """Two passes. Keystone resolves backward labels but not forward ones, so
    every label is emitted as an absolute address: pass one measures, pass two
    bakes. Each instruction is exactly four bytes, so the offsets cannot move
    between passes."""

    def __init__(self, ks, base):
        self.ks = ks
        self.base = base
        self.items = []
        self.labels = {}

    def label(self, name):
        self.items.append(('label', name, None))

    def emit(self, text, ref=None):
        """text may contain {t} where ref's absolute address goes."""
        self.items.append(('insn', text, ref))

    def _addr(self, name):
        if name not in self.labels:
            raise SystemExit('undefined label %s' % name)
        return self.base + self.labels[name]

    def assemble(self):
        # pass 1: offsets
        off = 0
        for kind, a, _ in self.items:
            if kind == 'label':
                self.labels[a] = off
            else:
                off += 4
        # pass 2: bytes
        out = bytearray()
        off = 0
        for kind, a, ref in self.items:
            if kind == 'label':
                continue
            text = a.format(t='0x%x' % self._addr(ref)) if ref else a
            try:
                chunk = bytes(self.ks.asm(text, self.base + off)[0])
            except Exception as exc:
                raise SystemExit('asm failed at %#x: %s (%s)' % (self.base + off, text, exc))
            if len(chunk) != 4:
                raise SystemExit('instruction is not 4 bytes: %s (%d)' % (text, len(chunk)))
            out.extend(chunk)
            off += 4
        return bytes(out)


class Stub:
    def __init__(self, base, stubs, dylibs, entry):
        self.base = base
        self.stubs = stubs
        self.dylibs = dylibs
        self.entry = entry
        self.ks = keystone.Ks(keystone.KS_ARCH_ARM64, keystone.KS_MODE_LITTLE_ENDIAN)

        self.paths = ['/.' + n for n, _ in dylibs]
        off = CODE_RESERVE
        self.string_off = {}
        for s in ['TMPDIR'] + self.paths:
            self.string_off[s] = off
            off += len(s) + 1
        off = align_up(off, 16)
        self.blob_off = []
        for _, data in dylibs:
            self.blob_off.append(off)
            off = align_up(off + len(data), 16)
        self.total = off

    def addr(self, off):
        return self.base + off

    def build(self):
        a = Assembler(self.ks, self.base)

        a.emit('stp x19, x20, [sp, #-0x50]!')
        a.emit('stp x21, x22, [sp, #0x10]')
        a.emit('stp x23, x30, [sp, #0x20]')
        a.emit('stp x0, x1, [sp, #0x30]')
        a.emit('stp x2, x3, [sp, #0x40]')
        a.emit('sub sp, sp, #0x400')
        a.emit('mov x19, sp')

        self._lea(a, 'x0', self.addr(self.string_off['TMPDIR']))
        self._call(a, '_getenv')
        a.emit('cbz x0, {t}', 'done')
        a.emit('mov x20, x0')

        for i, (_, data) in enumerate(self.dylibs):
            a.emit('mov x1, x20')
            a.emit('mov x2, x19')
            a.label('copy%d' % i)
            a.emit('ldrb w3, [x1], #1')
            a.emit('strb w3, [x2], #1')
            a.emit('cbnz w3, {t}', 'copy%d' % i)
            a.emit('sub x2, x2, #1')

            self._lea(a, 'x4', self.addr(self.string_off[self.paths[i]]))
            a.label('sfx%d' % i)
            a.emit('ldrb w3, [x4], #1')
            a.emit('strb w3, [x2], #1')
            a.emit('cbnz w3, {t}', 'sfx%d' % i)

            a.emit('mov x0, x19')
            a.emit('mov x1, #0x601')      # O_WRONLY|O_CREAT|O_TRUNC
            a.emit('mov x2, #0x1ed')      # 0755
            self._call(a, '_open')
            a.emit('cmp w0, #0')
            a.emit('b.lt {t}', 'next%d' % i)
            a.emit('sxtw x21, w0')

            a.emit('mov x0, x21')
            self._lea(a, 'x1', self.addr(self.blob_off[i]))
            a.emit('movz x2, #0x%x' % (len(data) & 0xFFFF))
            if len(data) >> 16:
                a.emit('movk x2, #0x%x, lsl #16' % ((len(data) >> 16) & 0xFFFF))
            self._call(a, '_write')

            a.emit('mov x0, x21')
            self._call(a, '_close')

            a.emit('mov x0, x19')
            a.emit('mov x1, #0x102')      # RTLD_NOW|RTLD_GLOBAL
            self._call(a, '_dlopen')

            a.emit('mov x0, x19')
            self._call(a, '_unlink')
            a.label('next%d' % i)

        a.label('done')
        a.emit('add sp, sp, #0x400')
        a.emit('ldp x2, x3, [sp, #0x40]')
        a.emit('ldp x0, x1, [sp, #0x30]')
        a.emit('ldp x23, x30, [sp, #0x20]')
        a.emit('ldp x21, x22, [sp, #0x10]')
        a.emit('ldp x19, x20, [sp], #0x50')
        self._lea(a, 'x16', self.entry)
        a.emit('br x16')

        code = a.assemble()
        if len(code) > CODE_RESERVE:
            raise SystemExit('stub grew past its %#x-byte reservation (%d)'
                             % (CODE_RESERVE, len(code)))
        return code

    def _lea(self, a, reg, addr):
        a.emit('adrp %s, #0x%x' % (reg, addr & ~0xFFF))
        a.emit('add %s, %s, #0x%x' % (reg, reg, addr & 0xFFF))

    def _call(self, a, sym):
        if sym not in self.stubs:
            raise SystemExit('%s is not imported by the host: no stub to call' % sym)
        self._lea(a, 'x16', self.stubs[sym])
        a.emit('blr x16')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--binary', required=True)
    ap.add_argument('--dylib', action='append', default=[])
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    data = bytearray(open(args.binary, 'rb').read())
    m = MachO(bytes(data))

    text_vm = m.segment('__TEXT')[1]
    linkedit = m.segment('__LINKEDIT')
    entry_vaddr = text_vm + m.main[0]

    stubs = m.stub_addresses()
    missing = [s for s in NEEDED if s not in stubs]
    if missing:
        raise SystemExit('host does not import: %s' % ', '.join(missing))

    dylibs = [(os.path.basename(p), open(p, 'rb').read()) for p in args.dylib]

    new_vm = align_up(linkedit[1] + linkedit[2], PAGE)
    new_fileoff = align_up(len(data), PAGE)

    stub = Stub(new_vm, stubs, dylibs, entry_vaddr)
    code = stub.build()

    payload = bytearray(stub.total)
    payload[:len(code)] = code
    for s, off in stub.string_off.items():
        payload[off:off + len(s) + 1] = s.encode() + b'\0'
    for (_, blob), off in zip(dylibs, stub.blob_off):
        payload[off:off + len(blob)] = blob

    span = align_up(len(payload), PAGE)
    payload.extend(b'\0' * (span - len(payload)))

    lc = bytearray(72)
    struct.pack_into('<II', lc, 0, LC_SEGMENT_64, 72)
    struct.pack_into('<16s', lc, 8, b'__PXLOAD')
    struct.pack_into('<QQQQ', lc, 24, new_vm, span, new_fileoff, span)
    struct.pack_into('<ii', lc, 56, 5, 5)      # maxprot, initprot = RX
    struct.pack_into('<II', lc, 64, 0, 0)      # nsects, flags

    first_fileoff = min(s[4] for s in m.sections if s[4] != 0)
    if m.header_end + len(lc) > first_fileoff:
        raise SystemExit('no room in the header for another load command')

    # Overwrite, never insert: every Mach-O file offset (symtab, section data,
    # LC_MAIN.entryoff) is measured from the start of the file, so pushing
    # bytes in at the header silently invalidates all of them.
    data[m.header_end:m.header_end + len(lc)] = lc
    struct.pack_into('<I', data, 16, m.ncmds + 1)
    struct.pack_into('<I', data, 20, m.sizeofcmds + len(lc))

    found = False
    off = 32
    for _ in range(m.ncmds + 1):
        cmd, cs = struct.unpack_from('<II', data, off)
        if cmd == LC_MAIN:
            struct.pack_into('<Q', data, off + 8, new_fileoff)
            found = True
            break
        off += cs
    if not found:
        raise SystemExit('LC_MAIN vanished after patching')

    pad = new_fileoff - len(data)
    if pad < 0:
        raise SystemExit('segment offset landed before end of file')
    data.extend(b'\0' * pad)
    data.extend(payload)
    open(args.out, 'wb').write(data)

    print('dylibs  : %s' % ', '.join('%s %d B' % (n, len(b)) for n, b in dylibs))
    print('stub    : %d B, entry now %#x' % (len(code), new_vm))
    print('segment : vm %#x + %#x, file %#x + %#x' % (new_vm, span, new_fileoff, span))
    print('wrote   : %s (%d B)' % (args.out, len(data)))


if __name__ == '__main__':
    main()
