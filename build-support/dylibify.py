#!/usr/bin/env python3
"""
dylibify.py — Linux port of LiveContainer/dylibify (jakeajames), used to turn a
Mach-O MH_EXECUTE into a loadable MH_DYLIB so it can be embedded as
Frameworks/SideStoreApp.framework and dlopen'd by LiveContainer.

Same-size, in-place patches (no load-command insertion):
  * mach_header: filetype MH_EXECUTE -> MH_DYLIB, flags |= MH_NO_REEXPORTED_DYLIBS
  * __PAGEZERO LC_SEGMENT_64 slot -> LC_ID_DYLIB (@executable_path/<name>)
  * LC_DYLD_INFO_ONLY: decrement segment index in rebase/bind opcodes
  * LC_DYLD_CHAINED_FIXUPS: drop the first (PAGEZERO) chained-starts segment
LC_MAIN is intentionally left untouched (matches the original tool).

Single-arch 64-bit only (what SideStore ships); errors out otherwise.
"""
import struct
import sys
import shutil
import os

MH_MAGIC_64 = 0xFEEDFACF
MH_DYLIB = 0x6
MH_NO_REEXPORTED_DYLIBS = 0x100000

LC_REQ_DYLD = 0x80000000
LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0xD
LC_DYLD_INFO_ONLY = 0x22 | LC_REQ_DYLD
LC_DYLD_CHAINED_FIXUPS = 0x34 | LC_REQ_DYLD

REBASE_OPCODE_MASK = 0xF0
REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB = 0x10

BIND_OPCODE_MASK = 0xF0
BIND_OPCODE_DO_BIND = 0x90
BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB = 0x70
BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM = 0x40
BIND_OPCODE_ADD_ADDR_ULEB = 0x20

SEGCMD64_SIZE = 72  # sizeof(struct segment_command_64)


def u32(b, off):
    return struct.unpack_from("<I", b, off)[0]


def put_u32(b, off, val):
    struct.pack_into("<I", b, off, val & 0xFFFFFFFF)


def patch_pagezero(b, off, cmdsize, install_name):
    # Overwrite the whole __PAGEZERO segment_command_64 slot with an LC_ID_DYLIB.
    block = bytearray(SEGCMD64_SIZE)
    struct.pack_into("<IIIiII", block, 0,
                     LC_ID_DYLIB,   # cmd
                     cmdsize,       # cmdsize (keep the slot size)
                     24,            # dylib.name.offset = sizeof(dylib_command)
                     1,             # timestamp
                     0,             # current_version
                     0)             # compatibility_version
    name = install_name.encode() + b"\x00"
    if 24 + len(name) > SEGCMD64_SIZE:
        raise SystemExit(f"[!] install name too long for the __PAGEZERO slot: {install_name}")
    block[24:24 + len(name)] = name
    b[off:off + SEGCMD64_SIZE] = block
    print(f"\t\t[+] __PAGEZERO -> LC_ID_DYLIB ({install_name})")


def patch_dyld_info(b, base, cmd_off):
    rebase_off = u32(b, cmd_off + 8)
    rebase_size = u32(b, cmd_off + 12)
    bind_off = u32(b, cmd_off + 16)
    bind_size = u32(b, cmd_off + 20)
    weak_off = u32(b, cmd_off + 24)
    weak_size = u32(b, cmd_off + 28)
    lazy_off = u32(b, cmd_off + 32)
    lazy_size = u32(b, cmd_off + 36)

    if rebase_off:
        for i in range(rebase_size):
            p = base + rebase_off + i
            if (b[p] & REBASE_OPCODE_MASK) == REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                b[p] -= 1
                print("\t\t[+] rebase SET_SEGMENT_AND_OFFSET_ULEB -1")
                break

    for name, boff, bsize in (("bind", bind_off, bind_size),
                              ("lazy_bind", lazy_off, lazy_size),
                              ("weak_bind", weak_off, weak_size)):
        if not boff:
            continue
        i = 0
        while i < bsize:
            p = base + boff + i
            op = b[p] & BIND_OPCODE_MASK
            if op == BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                if (b[p] & 0xF) == 2:
                    b[p] -= 1
                    print(f"\t\t[+] {name} SET_SEGMENT_AND_OFFSET_ULEB -1")
                while b[base + boff + i] != BIND_OPCODE_DO_BIND:
                    i += 1
            elif op == BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM:
                while b[base + boff + i] != 0:
                    i += 1
            elif op == BIND_OPCODE_ADD_ADDR_ULEB:
                while b[base + boff + i] != BIND_OPCODE_DO_BIND:
                    i += 1
            i += 1


def patch_chained_fixups(b, base, cmd_off):
    dataoff = u32(b, cmd_off + 8)
    datasize = u32(b, cmd_off + 12)
    if dataoff == 0 or datasize < 28:
        print("\t\t[!] invalid chained fixups payload")
        return
    hdr = base + dataoff
    starts_offset = u32(b, hdr + 4)
    if starts_offset == 0:
        print("\t\t[!] no chained starts to patch")
        return
    starts = hdr + starts_offset
    seg_count = u32(b, starts)
    if seg_count <= 1:
        print("\t\t[!] invalid chained starts seg table")
        return
    print(f"\t\t[-] chained starts seg_count before = {seg_count}")
    arr = starts + 4
    for i in range(seg_count - 1):
        put_u32(b, arr + i * 4, u32(b, arr + (i + 1) * 4))
    put_u32(b, arr + (seg_count - 1) * 4, 0)
    put_u32(b, starts, seg_count - 1)
    print(f"\t\t[+] chained starts seg_count now = {seg_count - 1}")


def dylibify(src, dst):
    if os.path.exists(dst):
        raise SystemExit(f"[!] {dst} already exists")
    shutil.copyfile(src, dst)
    with open(dst, "r+b") as f:
        b = bytearray(f.read())

        magic = u32(b, 0)
        if magic != MH_MAGIC_64:
            raise SystemExit(f"[!] not a single-arch 64-bit Mach-O (magic 0x{magic:x})")

        filetype = u32(b, 12)
        flags = u32(b, 24)
        print(f"[-] filetype was 0x{filetype:x}, flags 0x{flags:x}")
        put_u32(b, 12, MH_DYLIB)
        put_u32(b, 24, flags | MH_NO_REEXPORTED_DYLIBS)
        print(f"[+] filetype 0x{MH_DYLIB:x}, flags 0x{flags | MH_NO_REEXPORTED_DYLIBS:x}")

        ncmds = u32(b, 16)
        install_name = "@executable_path/" + os.path.basename(dst)
        off = 32
        for _ in range(ncmds):
            cmd = u32(b, off)
            cmdsize = u32(b, off + 4)
            if cmd == LC_SEGMENT_64:
                segname = bytes(b[off + 8:off + 8 + 16]).split(b"\x00")[0].decode(errors="replace")
                if segname == "__PAGEZERO":
                    patch_pagezero(b, off, cmdsize, install_name)
            elif cmd == LC_DYLD_INFO_ONLY:
                print("[*] LC_DYLD_INFO_ONLY")
                patch_dyld_info(b, 0, off)
            elif cmd == LC_DYLD_CHAINED_FIXUPS:
                print("[*] LC_DYLD_CHAINED_FIXUPS")
                patch_chained_fixups(b, 0, off)
            off += cmdsize

        f.seek(0)
        f.write(b)
        f.truncate()
    print(f"[+] wrote {dst}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <in-macho> <out-dylib>")
        sys.exit(1)
    dylibify(sys.argv[1], sys.argv[2])
