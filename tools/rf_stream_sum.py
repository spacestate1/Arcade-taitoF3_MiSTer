#!/usr/bin/env python3
"""Predict the skeleton core's on-screen download readouts.

Assembles the exact byte stream the MRA produces (interleaves included),
then folds it precisely the way Rayforce.sv does:

    word = 16-bit little-endian pair from the ioctl stream
    sum  = word                      for the first word
    sum  = rotl32(sum, 1) + word     for every later word   (mod 2^32)

Prints the two numbers the diagnostic screen must show after loading:
row 1 = byte count, row 2 = checksum. If the screen disagrees, the
download path is broken; if it agrees, MRA -> HPS -> ioctl -> core is
proven end to end.
"""
import sys, zipfile
import xml.etree.ElementTree as ET

mra = sys.argv[1] if len(sys.argv) > 1 else "releases/Ray Force.mra"
zpath = sys.argv[2] if len(sys.argv) > 2 else "gunlock.zip"

z = zipfile.ZipFile(zpath)
by_crc = {i.CRC & 0xFFFFFFFF: i for i in z.infolist()}


def part_bytes(el):
    # a padding part carries inline hex and a repeat count instead of a crc:
    #   <part repeat="1048576">00</part>
    if el.get("crc") is None:
        data = bytes(int(b, 16) for b in (el.text or "").split())
        return data * int(el.get("repeat", "1"))
    c = int(el.get("crc"), 16)
    data = z.read(by_crc[c])
    # offset/length take a WINDOW of the ROM, which is how MiSTer's own mra
    # tool reads them and how a set with a factory patch has to be expressed:
    # Grid Seeker's d40_03/04 are superseded in their bottom megabyte by the
    # patch ROMs d40_15/16, so only their upper halves are streamed. Without
    # this the assembled stream is a megabyte too long and the size check --
    # the thing that proves the regions line up with the RTL's base
    # addresses -- silently reports the wrong answer.
    off = int(el.get("offset", "0"), 0)
    ln = el.get("length")
    if off or ln is not None:
        end = off + int(ln, 0) if ln is not None else len(data)
        data = data[off:end]
    return data


stream = bytearray()
root = ET.parse(mra).getroot()
for rom in root.findall("rom"):
    if rom.get("index") != "0":
        continue
    for el in rom:
        if el.tag == "part":
            stream += part_bytes(el)
        elif el.tag == "interleave":
            parts = []
            for p in el.findall("part"):
                data = part_bytes(p)
                m = p.get("map")
                # map digits, rightmost = output byte 0; value = 1-based
                # index of the byte this part contributes per group
                lanes = {}
                for pos, ch in enumerate(reversed(m)):
                    if ch != "0":
                        lanes[pos] = int(ch) - 1
                parts.append((data, lanes, len(lanes)))
            osize = len(el.findall("part")[0].get("map"))
            groups = len(parts[0][0]) // parts[0][2]
            out = bytearray(osize * groups)
            for data, lanes, n in parts:
                for g in range(groups):
                    for opos, srcidx in lanes.items():
                        out[g * osize + opos] = data[g * n + srcidx]
            stream += out

total = len(stream)
s = 0
for i in range(0, total, 2):
    w = stream[i] | (stream[i + 1] << 8)
    if i == 0:
        s = w
    else:
        s = (((s << 1) | (s >> 31)) + w) & 0xFFFFFFFF

print(f"stream bytes : 0x{total:08X}  <- screen row 1")
print(f"checksum     : 0x{s:08X}  <- screen row 2")

# Phase 1 readback BIST: the FULL 1 MB maincpu region (start of the stream),
# read back through the SDRAM fetch path as the CPU sees it -- big-endian
# 16-bit words -- folded rotl1+add with the sum seeded at 0.
# Must match screen row 7 (bist_sum).
b = 0
for i in range(0, 0x100000, 2):
    w = (stream[i] << 8) | stream[i + 1]
    b = ((((b << 1) | (b >> 31)) & 0xFFFFFFFF) + w) & 0xFFFFFFFF

print(f"bist sum     : 0x{b:08X}  <- screen row 7")
