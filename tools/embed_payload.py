#!/usr/bin/env python3
"""Embed the injected dylibs inside the app's main binary.

No LC_LOAD_DYLIB, no file under Frameworks/, nothing for a bundle scan to find.

Layout produced (this ordering matters):

    __TEXT     ... load commands, then the entry stub in the header padding
    __DATA     unchanged
    __PXLOAD   NEW - blob store holding the dylib bytes (data only)
    __LINKEDIT moved to the end of the file, unchanged contents

__LINKEDIT *must* stay last. ldid (TrollStore's signer) appends its signature
at EOF by growing __LINKEDIT.filesize up to the end of the file. With a segment
sitting behind __LINKEDIT that grown range overlaps it, the kernel sees two
segments covering the same bytes and kills the process at exec - no log, no
process, nothing to read on the device.

Nothing is inserted into the file. Every Mach-O file offset is measured from
byte zero, so pushing bytes in at the header invalidates the symtab, every
section, and LC_MAIN at once. The stub goes into existing zero padding between
the load commands and __TEXT,__text.

The stub calls libSystem through the host's own __stubs table, so it needs no
bind entries of its own and nothing to relocate: every address it touches is
PC-relative inside the image and slide-correct by construction.

Usage:
    python tools/embed_payload.py --binary Path/DeltaForceClient \
        --dylib a.dylib --dylib b.dylib --out Path/DeltaForceClient.out

    python tools/embed_payload.py --binary ... --probe --out ...   # structural test
"""

import argparse
import os
import struct

import keystone

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_MAIN = 0x80000028

PAGE = 0x4000        # arm64 iOS page size
STUB_FILEOFF = 0x3900  # free padding inside __TEXT, after the load commands
STRING_BASE = 0x1000   # offset inside __PXLOAD where the literal strings live

# libSystem entry points the stub needs. All of these are already imported by
# the host, so their stubs exist and resolve before LC_MAIN runs.
NEEDED = ['_getenv', '_open', '_write', '_close', '_dlopen', '_unlink']

# Load commands whose payload lives in __LINKEDIT, as (field offset, width).
# LC_ENCRYPTION_INFO_64 is deliberately absent: its cryptoff points into __TEXT
# and must not move.
LINKEDIT_DATA_CMDS = {
    0x1D: [(8, 4)],          # LC_CODE_SIGNATURE
    0x1E: [(8, 4)],          # LC_SEGMENT_SPLIT_INFO
    0x26: [(8, 4)],          # LC_FUNCTION_STARTS
    0x29: [(8, 4)],          # LC_DATA_IN_CODE
    0x2B: [(8, 4)],          # LC_DYLIB_CODE_SIGN_DRS
    0x80000033: [(8, 4)],    # LC_DYLD_EXPORTS_TRIE
    0x80000034: [(8, 4)],    # LC_DYLD_CHAINED_FIXUPS
}


def align_up(v, a):
    return (v + a - 1) & ~(a - 1)


class MachO:
    def __init__(self, data):
        self.d = data
        if struct.unpack_from('<I', data, 0)[0] != 0xFEEDFACF:
            raise SystemExit('not a thin little-endian Mach-O')
        self.ncmds, self.sizeofcmds = struct.unpack_from('<II', data, 16)
        self.segments = []      # (name, vmaddr, vmsize, fileoff, filesize, cmdoff)
        self.sections = []      # (segname, sectname, addr, size, fileoff, flags, r1)
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
                self.segments.append((name, vmaddr, vmsize, fileoff, filesize, off))
                for s in range(nsects):
                    so = off + 72 + s * 80
                    sect = data[so:so + 16].split(b'\0')[0].decode()
                    seg = data[so + 16:so + 32].split(b'\0')[0].decode()
                    addr, size = struct.unpack_from('<QQ', data, so + 32)
                    fo = struct.unpack_from('<I', data, so + 48)[0]
                    flags = struct.unpack_from('<I', data, so + 64)[0]
                    r1 = struct.unpack_from('<I', data, so + 68)[0]
                    self.sections.append((seg, sect, addr, size, fo, flags, r1))
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

        __stubs' own indirect index is not aligned with __stubs: the last few
        entries read __got instead of __la_symbol_ptr, so trusting reserved1
        maps _unlink onto a __mod_init_func slot. Decode each stub, work out
        which pointer section it actually reads, and take the name from that
        section's indirect table.
        """
        stubs = self.section('__TEXT', '__stubs')
        if not stubs:
            raise SystemExit('no __TEXT,__stubs section')
        _, _, stub_addr, stub_size, stub_off, _, _ = stubs

        slots = [s for s in self.sections if (s[5] & 0xFF) in (0x6, 0x7)]
        indirect_off, n_indirect = self.dysymtab[12], self.dysymtab[13]
        out = {}
        for i in range(stub_size // 12):
            va = stub_addr + i * 12
            w0, w1, w2 = struct.unpack_from('<III', self.d, stub_off + i * 12)
            if (w0 & 0x9F00001F) != 0x90000010:      # adrp x16
                continue
            if (w1 & 0xFFC00000) != 0xF9400000:      # ldr x16, [x16, #imm]
                continue
            if w2 != 0xD61F0200:                     # br x16
                continue
            imm = ((((w0 >> 5) & 0x7FFFF) << 2) | ((w0 >> 29) & 3))
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
    bakes. Each instruction is exactly four bytes, so offsets cannot move."""

    def __init__(self, ks, base):
        self.ks = ks
        self.base = base
        self.items = []
        self.labels = {}

    def label(self, name):
        self.items.append(('label', name, None))

    def emit(self, text, ref=None):
        self.items.append(('insn', text, ref))

    def _addr(self, name):
        if name not in self.labels:
            raise SystemExit('undefined label %s' % name)
        return self.base + self.labels[name]

    def assemble(self):
        off = 0
        for kind, a, _ in self.items:
            if kind == 'label':
                self.labels[a] = off
            else:
                off += 4
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
    """The loader: write each dylib into TMPDIR, dlopen it, unlink it, then jump
    to the real entry point. Built for --probe it just jumps."""

    def __init__(self, ks, px_vm, code_vm, stubs, dylibs, entry):
        self.ks = ks
        self.px_vm = px_vm
        self.code_vm = code_vm
        self.stubs = stubs
        self.dylibs = dylibs
        self.entry = entry

        self.strings = {}
        off = STRING_BASE
        for s in ['TMPDIR'] + ['/.' + n for n, _ in dylibs]:
            self.strings[s] = off
            off += len(s) + 1
        off = align_up(off, 16)
        self.blobs = []
        for _, data in dylibs:
            self.blobs.append(off)
            off = align_up(off + len(data), 16)
        self.total = off

    def blob_addr(self, i):
        return self.px_vm + self.blobs[i]

    def build(self):
        a = Assembler(self.ks, self.code_vm)

        a.emit('stp x19, x20, [sp, #-0x50]!')
        a.emit('stp x21, x22, [sp, #0x10]')
        a.emit('stp x23, x30, [sp, #0x20]')
        a.emit('stp x0, x1, [sp, #0x30]')
        a.emit('stp x2, x3, [sp, #0x40]')
        a.emit('sub sp, sp, #0x400')
        a.emit('mov x19, sp')

        if not self.dylibs:
            a.emit('b {t}', 'done')
        else:
            self._lea(a, 'x0', self.px_vm + self.strings['TMPDIR'])
            self._call(a, '_getenv')
            a.emit('cbz x0, {t}', 'done')
            a.emit('mov x20, x0')

            for i, (name, data) in enumerate(self.dylibs):
                a.emit('mov x1, x20')
                a.emit('mov x2, x19')
                a.label('copy%d' % i)
                a.emit('ldrb w3, [x1], #1')
                a.emit('strb w3, [x2], #1')
                a.emit('cbnz w3, {t}', 'copy%d' % i)
                a.emit('sub x2, x2, #1')

                self._lea(a, 'x4', self.px_vm + self.strings['/.' + name])
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
                self._lea(a, 'x1', self.blob_addr(i))
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
        if STUB_FILEOFF + len(code) > self.text_text_off():
            raise SystemExit('stub overruns __text (needs %d bytes)' % len(code))
        return code

    def text_text_off(self):
        return 0x4000   # __TEXT,__text starts here; matches the assert in main()

    def _lea(self, a, reg, addr):
        a.emit('adrp %s, #0x%x' % (reg, addr & ~0xFFF))
        a.emit('add %s, %s, #0x%x' % (reg, reg, addr & 0xFFF))

    def _call(self, a, sym):
        if sym not in self.stubs:
            raise SystemExit('%s is not imported by the host: no stub to call' % sym)
        self._lea(a, 'x16', self.stubs[sym])
        a.emit('blr x16')


def patch_linkedit_refs(buf, cmdoff, cmd, cmdsize, old_le, old_size, delta):
    """Shift every file offset that points into the old __LINKEDIT."""
    def bump(field_off, width):
        if field_off + width > cmdsize:
            return
        fmt = '<I' if width == 4 else '<Q'
        v = struct.unpack_from(fmt, buf, cmdoff + field_off)[0]
        if v and old_le <= v < old_size:
            struct.pack_into(fmt, buf, cmdoff + field_off, v + delta)

    if cmd in LINKEDIT_DATA_CMDS:
        for field_off, width in LINKEDIT_DATA_CMDS[cmd]:
            bump(field_off, width)
    elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
        for k in range(5):
            bump(8 + k * 8, 4)
    elif cmd == LC_SYMTAB:
        bump(8, 4)      # symoff
        bump(16, 4)     # stroff
    elif cmd == LC_DYSYMTAB:
        for idx in (6, 8, 10, 12, 14, 16):
            bump(8 + idx * 4, 4)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--binary', required=True)
    ap.add_argument('--dylib', action='append', default=[])
    ap.add_argument('--probe', action='store_true',
                    help='structural test: add the segment and the entry hop, but load nothing')
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    data = bytearray(open(args.binary, 'rb').read())
    m = MachO(bytes(data))
    old_size = len(data)

    text = m.segment('__TEXT')
    data_seg = m.segment('__DATA')
    linkedit = m.segment('__LINKEDIT')     # (name, vmaddr, vmsize, fileoff, filesize, cmdoff)
    text_vm = text[1]
    le_vmaddr, le_vmsize, le_fileoff, le_filesize = linkedit[1:5]

    if le_fileoff + le_filesize != old_size:
        raise SystemExit('__LINKEDIT does not end the file: refusing to relayout')

    stubs = m.stub_addresses()
    entry_vaddr = text_vm + m.main[0]

    dylibs = [] if args.probe else [
        (os.path.basename(p), open(p, 'rb').read()) for p in args.dylib
    ]
    missing = [s for s in NEEDED if s not in stubs]
    if missing and dylibs:
        raise SystemExit('host does not import: %s' % ', '.join(missing))

    # __DATA reserves zero-fill beyond its file bytes, so vmaddr != __TEXT vmaddr
    # + fileoff past that point. Derive vm addresses from the segment table
    # instead of assuming the two advance together.
    px_fileoff = le_fileoff
    px_vm = align_up(data_seg[1] + data_seg[2], PAGE)
    if px_vm != le_vmaddr:
        raise SystemExit('unexpected gap between __DATA and __LINKEDIT in vm')

    text_text = m.section('__TEXT', '__text')
    if text_text and STUB_FILEOFF + 0x400 > text_text[2] - text_vm:
        raise SystemExit('header padding too small for the stub')

    stub = Stub(keystone.Ks(keystone.KS_ARCH_ARM64, keystone.KS_MODE_LITTLE_ENDIAN),
                px_vm, text_vm + STUB_FILEOFF, stubs, dylibs, entry_vaddr)
    code = stub.build()

    payload = bytearray(stub.total if dylibs else STRING_BASE)
    for s, off in stub.strings.items():
        payload[off:off + len(s) + 1] = s.encode() + b'\0'
    for (_, blob), off in zip(dylibs, stub.blobs):
        payload[off:off + len(blob)] = blob

    px_filesize = align_up(len(payload), PAGE)
    payload.extend(b'\0' * (px_filesize - len(payload)))

    new_le_fileoff = align_up(px_fileoff + px_filesize, PAGE)
    delta = new_le_fileoff - le_fileoff
    if delta % PAGE:
        raise SystemExit('internal: __LINKEDIT moved by a non-page delta')

    out = bytearray()
    out += data[:px_fileoff]              # header + __TEXT + __DATA, untouched order
    # the stub lives in __TEXT padding, so write it into the header region
    out[STUB_FILEOFF:STUB_FILEOFF + len(code)] = code
    out += payload
    out += b'\0' * (new_le_fileoff - len(out))
    out += data[le_fileoff:le_fileoff + le_filesize]

    # __LINKEDIT relocates to the end of the file: rewrite its vmaddr/fileoff.
    # segment_command_64: vmaddr@24 vmsize@32 fileoff@40 filesize@48
    le_cmdsize = struct.unpack_from('<I', out, linkedit[5] + 4)[0]
    le_cmd = bytearray(out[linkedit[5]:linkedit[5] + le_cmdsize])
    struct.pack_into('<Q', le_cmd, 24, align_up(px_vm + px_filesize, PAGE))
    struct.pack_into('<Q', le_cmd, 40, new_le_fileoff)

    # new load command for the blob store
    lc = bytearray(72)
    struct.pack_into('<II', lc, 0, LC_SEGMENT_64, 72)
    struct.pack_into('<16s', lc, 8, b'__PXLOAD')
    struct.pack_into('<QQQQ', lc, 24, px_vm, px_filesize, px_fileoff, px_filesize)
    struct.pack_into('<ii', lc, 56, 5, 5)          # maxprot, initprot = RX
    struct.pack_into('<II', lc, 64, 0, 0)          # nsects, flags

    # Segments must appear in vmaddr order, so __PXLOAD takes __LINKEDIT's old
    # slot and __LINKEDIT's command moves to the end of the list.
    if m.header_end + len(lc) > STUB_FILEOFF:
        raise SystemExit('no room in the header for another load command')
    out[linkedit[5]:linkedit[5] + le_cmdsize] = lc
    out[m.header_end:m.header_end + le_cmdsize] = le_cmd
    struct.pack_into('<I', out, 16, m.ncmds + 1)
    struct.pack_into('<I', out, 20, m.sizeofcmds + le_cmdsize)

    # walk the final command list: retarget LC_MAIN and relocate linkedit refs
    off = 32
    main_seen = False
    for _ in range(m.ncmds + 1):
        cmd, cs = struct.unpack_from('<II', out, off)
        if cmd == LC_MAIN:
            struct.pack_into('<Q', out, off + 8, STUB_FILEOFF)
            main_seen = True
        else:
            patch_linkedit_refs(out, off, cmd, cs, le_fileoff, old_size, delta)
        off += cs
    if not main_seen:
        raise SystemExit('LC_MAIN vanished after patching')

    open(args.out, 'wb').write(out)

    print('dylibs   : %s' % (', '.join('%s %d B' % (n, len(b)) for n, b in dylibs) or 'none (probe)'))
    print('stub     : %d B at file %#x (vaddr %#x), inside __TEXT' % (len(code), STUB_FILEOFF, text_vm + STUB_FILEOFF))
    print('__PXLOAD : vm %#x + %#x, file %#x + %#x' % (px_vm, px_filesize, px_fileoff, px_filesize))
    print('__LINKEDIT: file %#x -> %#x (+%#x), now last' % (le_fileoff, new_le_fileoff, delta))
    print('entry    : %#x -> %#x' % (entry_vaddr, text_vm + STUB_FILEOFF))
    print('wrote    : %s (%d B)' % (args.out, len(out)))


if __name__ == '__main__':
    main()
