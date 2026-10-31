import struct
import capstone

d = open(r'D:\delta\_pxbin', 'rb').read()
md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
stub_base = 0x110d004c0
n = 0x6CE4 // 12
text_vm = 0x100000000
la = (0x1138108E8, 0x1138108E8 + 0x4600)
got = (0x11380C000, 0x11380C000 + 0x48E8)

counts = {'la': 0, 'got': 0, 'other': 0}
samples = []
for i in range(n):
    va = stub_base + i * 12
    code = d[va - text_vm:va - text_vm + 12]
    ins = list(md.disasm(code, va))
    if len(ins) < 2:
        counts['other'] += 1
        samples.append((i, hex(va), 'short'))
        continue
    try:
        page = int(ins[0].op_str.split('#')[1], 16)
        imm = int(ins[1].op_str.split(', #')[1].rstrip(']'), 16)
    except Exception:
        counts['other'] += 1
        samples.append((i, hex(va), ins[0].mnemonic + ' ' + ins[0].op_str))
        continue
    addr = page + imm
    if la[0] <= addr < la[1]:
        counts['la'] += 1
    elif got[0] <= addr < got[1]:
        counts['got'] += 1
    else:
        counts['other'] += 1
        if len(samples) < 8:
            samples.append((i, hex(va), hex(addr)))

print('stubs', n, counts)
print(samples)
