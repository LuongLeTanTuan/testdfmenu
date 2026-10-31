import struct, sys

p = sys.argv[1] if len(sys.argv) > 1 else r'D:\delta\Payload\DeltaForceClient.app\DeltaForceClient'
d = open(p, 'rb').read()
ncmds = struct.unpack_from('<I', d, 16)[0]
off = 32
symtab = None
dys = None
for _ in range(ncmds):
    cmd, cs = struct.unpack_from('<II', d, off)
    if cmd == 0x2:
        symtab = struct.unpack_from('<IIII', d, off + 8)
    elif cmd == 0xb:
        dys = struct.unpack_from('<IIIIIIIIIIIIIIIIIIII', d, off + 8)
    off += cs

symoff, nsyms, stroff, strsize = symtab
# dysymtab: cmd,cmdsize,ilocalsym,nlocalsym,iextdefsym,nextdefsym,iundefsym,nundefsym,
#           tocoff,ntoc,modtaboff,nmodtab,extrefsymoff,nextrefsyms,indirectsymoff,nindirectsyms,
#           extreloff,nextrel,locreloff,nlocrel
ilocalsym, nlocalsym, iextdefsym, nextdefsym, iundefsym, nundefsym = dys[0:6]
indirectsymoff, nindirectsyms = dys[12], dys[13]

print('symtab off=%#x n=%d stroff=%#x size=%d' % (symoff, nsyms, stroff, strsize))
print('undef  start=%d n=%d  indirect off=%#x n=%d' % (iundefsym, nundefsym, indirectsymoff, nindirectsyms))


def name_at(idx):
    n_strx = struct.unpack_from('<I', d, symoff + idx * 16)[0]
    if n_strx >= strsize:
        return None
    end = d.index(b'\x00', stroff + n_strx)
    return d[stroff + n_strx:end].decode('utf-8', 'replace')


undef = []
for k in range(iundefsym, iundefsym + nundefsym):
    undef.append(name_at(k))
have = set(n for n in undef if n)

want = ['_dlopen', '_dlsym', '_unlink', '_open', '_write', '_read', '_close', '_getpid',
        '_proc_pidpath', '_fopen', '_fread', '_fwrite', '_mmap', '_strcpy', '_strlcpy',
        '_remove', '_rename', '_NSGetExecutablePath', '_getattrlist', '_stat', '_mkdir',
        '_objc_msgSend', '_objc_getClass', '_sel_registerName', '_NSClassFromString',
        '_objc_getMetaClass', '_class_getName', '_sysctl', '_sysctlbyname']
print()
print('--- wanted ---')
for w in want:
    print('  %-24s %s' % (w, 'yes' if w in have else 'NO'))

print()
print('--- all undefined (%d) ---' % len(have))
for n in sorted(have):
    print('   ', n)
