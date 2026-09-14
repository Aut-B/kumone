#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Gate the CI build: the artifact must be an arm64/iOS Mach-O dylib whose code
signature is self-consistent and ad-hoc (i.e. produced by `codesign -s -`, not
by the linker).

Only hard invariants fail the job. Cosmetic facts (CodeDirectory version, page
size, special-slot count, blob padding) are printed but tolerated, because
Xcode's codesign changes them between releases and a false failure here would
block a perfectly good dylib.

Usage: python3 verify_shape.py VVeboMultiFix.dylib
"""
import hashlib
import struct
import sys

CPUTYPE_ARM64 = 0x0100000C
MH_DYLIB = 6
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSMAGIC_REQUIREMENTS = 0xFADE0C01
CSMAGIC_BLOBWRAPPER = 0xFADE0B01
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE0CC1
CSMAGIC_EMBEDDED_DER_ENTITLEMENTS = 0xFADE0CC1

CS_ADHOC = 0x2
CS_LINKER_SIGNED = 0x20000

SLOT_NAMES = {
    0x0: "CodeDirectory",
    0x1: "Info.plist",
    0x2: "Requirements",
    0x3: "ResourceDir",
    0x4: "Application",
    0x5: "Entitlements",
    0x10000: "CMS (BlobWrapper)",
}

fail = []


def check(ok, msg):
    print(("  ok    " if ok else "  FAIL  ") + msg)
    if not ok:
        fail.append(msg)
    return ok


def note(msg):
    print("  note  " + msg)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "VVeboMultiFix.dylib"
    d = open(path, "rb").read()
    print(f"[file] {path}: {len(d)} bytes, sha256={hashlib.sha256(d).hexdigest()}")

    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack(
        "<IIIIIIII", d[:32])
    check(magic == 0xFEEDFACF, f"Mach-O 64 magic ({magic:#x})")
    check(cputype == CPUTYPE_ARM64, f"cputype arm64 ({cputype:#x})")
    check(filetype == MH_DYLIB, f"filetype MH_DYLIB ({filetype})")

    p, sigcmd, sigcmd_off, sig, bv, le = 32, None, None, None, None, None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", d[p:p + 8])
        if cmd == LC_CODE_SIGNATURE:
            sigcmd = p
            sig = struct.unpack("<II", d[p + 8:p + 16])
        elif cmd == LC_BUILD_VERSION:
            bv = struct.unpack("<IIII", d[p + 8:p + 24])
        elif cmd == LC_SEGMENT_64 and d[p + 8:p + 24].split(b"\x00")[0] == b"__LINKEDIT":
            le = struct.unpack("<QQQQ", d[p + 24:p + 56])
        p += cmdsize
    check(p == 32 + sizeofcmds, "load command area is contiguous")
    check(bv is not None and bv[0] == 2, f"platform == iOS (2), got {bv and bv[0]}")
    if bv:
        note(f"minos {bv[1] >> 16}.{(bv[1] >> 8) & 0xff}  sdk {bv[2] >> 16}.{(bv[2] >> 8) & 0xff}")
    if not check(sig is not None, "LC_CODE_SIGNATURE present"):
        return done()

    so, ss = sig
    note(f"signature at {so:#x}, datasize {ss:#x}, file {len(d):#x}")

    # ---- SuperBlob ------------------------------------------------------
    sbm, sbl, sbc = struct.unpack(">III", d[so:so + 12])
    check(sbm == CSMAGIC_EMBEDDED_SIGNATURE, f"SuperBlob magic ({sbm:#x})")
    check(so + sbl <= len(d), f"SuperBlob ({sbl} B) fits in the file")
    if so + sbl != len(d):
        note(f"SuperBlob padding: blob ends {so + sbl:#x}, file ends {len(d):#x}")

    slots = {}
    for i in range(sbc):
        st, sof = struct.unpack(">II", d[so + 12 + i * 8:so + 20 + i * 8])
        m, ln = struct.unpack(">II", d[so + sof:so + sof + 8])
        slots[st] = (sof, m, ln)
        note(f"slot {st:#08x} {SLOT_NAMES.get(st, '?'):16s} off {sof:#x} len {ln:#x} magic {m:#x}")
    check(0 in slots and slots[0][1] == CSMAGIC_CODEDIRECTORY, "slot 0 is the CodeDirectory")

    # ---- CodeDirectory --------------------------------------------------
    cd_off = so + slots[0][0]
    # magic + length are the first 8 bytes; the fields below start right after
    (cv, cf, cho, cio, cns, cnc, ccl,
     chs, cht, cpla, cps) = struct.unpack(">IIIIIIIBBBB", d[cd_off + 8:cd_off + 40])
    clen = slots[0][2]
    note(f"CD v{cv:#x} len {clen} flags {cf:#x} nSpecial {cns} nCode {cnc} "
         f"codeLimit {ccl:#x} hash {chs}B type {cht} page {1 << cps}")
    check(cf & CS_ADHOC, f"CS_ADHOC set (flags {cf:#x})")
    check(not (cf & CS_LINKER_SIGNED), f"not linker-signed (flags {cf:#x})")
    check(chs == 32 and cht == 2, f"SHA-256 hashes (size={chs}, type={cht})")
    check(ccl == so, f"codeLimit == signature offset ({ccl:#x} vs {so:#x})")
    check(clen <= slots[0][2], f"CodeDirectory length {clen} fits its blob {slots[0][2]}")

    page = 1 << cps
    bad = [i for i in range(cnc)
           if hashlib.sha256(d[i * page:min((i + 1) * page, ccl)]).digest()
           != d[cd_off + cho + i * chs:cd_off + cho + (i + 1) * chs]]
    check(not bad, f"all {cnc} page hashes match the file ({len(bad)} bad)")

    # slot -2 must hash the requirements blob (that is what codesign writes)
    if 2 in slots and cns >= 2:
        reqoff, _, reql = slots[2]
        stored = d[cd_off + cho - 2 * chs:cd_off + cho - chs]
        check(stored == hashlib.sha256(d[so + reqoff:so + reqoff + reql]).digest(),
              "slot -2 == hash(requirements blob)")

    done()


def done():
    if fail:
        print(f"\nVERDICT: FAILED ({len(fail)} check(s))")
        sys.exit(1)
    print("\nVERDICT: OK - arm64/iOS dylib with a self-consistent ad-hoc codesign signature")


if __name__ == "__main__":
    main()
