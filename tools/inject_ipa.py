#!/usr/bin/env python3
"""inject_ipa.py — add LC_LOAD_DYLIB entries to an already-decrypted .app
bundle and repack an IPA, without insert_dylib / ldid / a Mac.

The app binary here has 0x7C8 bytes of slack between the end of the load
commands (0x3838) and __TEXT,__text (0x4000), which is where the commands go.
Any installer (TrollStore, Sideloadly, eSign) re-signs the bundle afterwards,
so the old LC_CODE_SIGNATURE is left in place and simply overwritten.

    python tools/inject_ipa.py --app Payload/DeltaForceClient.app \
        --dylib build-artifacts/PxMenu.dylib --dylib build-artifacts/AnoMute.dylib \
        --verify-only
    python tools/inject_ipa.py --app Payload/DeltaForceClient.app \
        --dylib build-artifacts/PxMenu.dylib --dylib build-artifacts/AnoMute.dylib \
        --out DeltaForce_PxMenu.ipa
"""
import argparse
import os
import shutil
import struct
import sys
import tempfile
import zipfile

LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
MH_MAGIC_64 = 0xFEEDFACF


def load_commands(blob):
    """Yield (offset, cmd, cmdsize, name) for every load command."""
    ncmds, sizeofcmds = struct.unpack_from("<II", blob, 16)
    off = 32
    end = 32 + sizeofcmds
    for _ in range(ncmds):
        if off + 8 > end:
            raise ValueError("load-command table overruns sizeofcmds")
        cmd, cmdsize = struct.unpack_from("<II", blob, off)
        if cmdsize < 8 or off + cmdsize > end:
            raise ValueError(f"bad cmdsize {cmdsize} at {off:#x}")
        name = None
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            nameoff = struct.unpack_from("<I", blob, off + 8)[0]
            raw = blob[off + nameoff:off + cmdsize]
            name = raw.split(b"\x00")[0].decode("utf-8", "replace")
        yield off, cmd, cmdsize, name
        off += cmdsize


def existing_dylibs(blob):
    return [n for _, c, _, n in load_commands(blob) if c in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB)]


def first_section_offset(blob):
    """Lowest file offset of any section with content: the hard ceiling."""
    lowest = None
    for off, cmd, cmdsize, _ in load_commands(blob):
        if cmd != 0x19:  # LC_SEGMENT_64
            continue
        nsects = struct.unpack_from("<I", blob, off + 64)[0]
        so = off + 72
        for _ in range(nsects):
            size, foff = struct.unpack_from("<QI", blob, so + 40)
            if size and foff and (lowest is None or foff < lowest):
                lowest = foff
            so += 80
    return lowest


def add_dylib(blob, path):
    if path in existing_dylibs(blob):
        return blob, False
    ncmds, sizeofcmds = struct.unpack_from("<II", blob, 16)
    cmds_end = 32 + sizeofcmds
    ceiling = first_section_offset(blob)
    entry = 24 + len(path.encode()) + 1
    entry = (entry + 7) & ~7  # 8-byte aligned, like the linker emits

    if cmds_end + entry > ceiling:
        raise SystemExit(f"not enough header slack: need {entry} B, have {ceiling - cmds_end} B")

    name_off = 24
    struct.pack_into("<IIIIII", blob, cmds_end,
                     LC_LOAD_DYLIB, entry, name_off, 2, 0x10000, 0x10000)
    blob[cmds_end + name_off:cmds_end + name_off + len(path)] = path.encode()
    struct.pack_into("<II", blob, 16, ncmds + 1, sizeofcmds + entry)
    return blob, True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True, help="path to <Name>.app bundle")
    ap.add_argument("--dylib", action="append", default=[],
                    help="dylib to copy into Frameworks/ and load; repeatable")
    ap.add_argument("--out", help="write this IPA")
    ap.add_argument("--verify-only", action="store_true",
                    help="patch a temp copy of the binary and report, change nothing")
    args = ap.parse_args()

    executable = os.path.join(args.app, os.path.basename(args.app)[:-4])
    if not os.path.isfile(executable):
        sys.exit(f"no executable at {executable}")

    blob = bytearray(open(executable, "rb").read())
    if struct.unpack_from("<I", blob, 0)[0] != MH_MAGIC_64:
        sys.exit("not a thin 64-bit mach-o")

    targets = [f"@rpath/{os.path.basename(d)}" for d in args.dylib]
    for t in targets:
        blob, added = add_dylib(blob, t)
        print(f"{'added  ' if added else 'present'} {t}")

    names = existing_dylibs(blob)
    assert all(t in names for t in targets), "verification failed: entry missing after write"
    print(f"load commands: {len(names)} (was {len(names) - len(targets)})")

    if args.verify_only:
        print("verify-only: nothing written")
        return

    open(executable, "wb").write(blob)

    fw = os.path.join(args.app, "Frameworks")
    os.makedirs(fw, exist_ok=True)
    for d in args.dylib:
        shutil.copy2(d, os.path.join(fw, os.path.basename(d)))
        os.chmod(os.path.join(fw, os.path.basename(d)), 0o755)

    # The old signature covers the old bytes; the installer writes a new one.
    shutil.rmtree(os.path.join(args.app, "_CodeSignature"), ignore_errors=True)

    if args.out:
        root = os.path.dirname(os.path.abspath(args.app))
        tmp = tempfile.mkdtemp()
        stage = os.path.join(tmp, "Payload")
        shutil.copytree(args.app, os.path.join(stage, os.path.basename(args.app)),
                        symlinks=True)
        import time
        exe_name = os.path.basename(executable)
        with zipfile.ZipFile(args.out, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as z:
            for base, _, files in os.walk(stage):
                for f in files:
                    full = os.path.join(base, f)
                    arc = os.path.relpath(full, tmp).replace(os.sep, "/")
                    z.write(full, arc)
                    # Windows has no unix mode, so zipfile records 0644 for
                    # everything; the app binary must stay executable or the
                    # installer copies a non-runnable bundle.
                    zi = z.getinfo(arc)
                    exec_bit = f == exe_name or f.endswith(".dylib")
                    zi.external_attr = ((0o100755 if exec_bit else 0o100644) & 0xFFFF) << 16
        shutil.rmtree(tmp, ignore_errors=True)
        print(f"wrote {args.out} ({os.path.getsize(args.out)/1048576:.0f} MB)")


if __name__ == "__main__":
    main()
