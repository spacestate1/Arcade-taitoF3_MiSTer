#!/usr/bin/env python3
"""Decode and sanity-check the config bytes of every shipped MRA.

    python3 tools/check_mra_cfg.py           # table + checks, exit 1 on failure
    python3 tools/check_mra_cfg.py --quiet   # checks only

Every other gate in this project validates a TRANSFORM: the benches feed
RTL a stream captured from MAME and compare the output. None of them
validate the INPUT. The config bytes in an MRA are pure input -- they tell
the core which game it is, how big its ROM map is and where its palette
format differs -- and a wrong one produces a core that renders a different
game's geometry with every bench still passing.

That is not hypothetical. On 2026-09-08 nine of thirteen generated MRAs had
the wrong game id: Land Maker decoded as 21 and collided with Riding Fight,
Top Ranking Stars as 22 and collided with Ring Rage, and `map` was set on
none of the profile-1 sets at all. Nothing in the build or the benches could
have noticed. This script is the gate that would have.

Byte layout, from Rayforce.sv:

    ioctl index 1:  [7:6] id low   [5] id mid   [4:3] start zone
                    [2]   ~extend  [1:0] visible area
    ioctl index 2:  [7:6] uart     [5] pal12    [4] map profile
                    [2:0] id high

    game id = {index2[2:0], index1[5], index1[7:6]}
"""
import argparse
import collections
import glob
import os
import re
import sys

# Games whose 12-bit palette is switched on by the RTL id table
# (Rayforce.sv cfg_pal12_id), so their MRA bit is expected to be 0.
PAL12_BY_ID = {20, 21, 22}

# Variant MRAs that deliberately share a base game's id.
VARIANT = re.compile(r"\((zone 2|write ring)\)")


def first_part_after(text, index):
    m = re.search(r'index="%d"' % index, text)
    if not m:
        return None
    p = re.search(r"<part>\s*([0-9A-Fa-f]{1,2})\s*</part>", text[m.end():])
    return int(p.group(1), 16) if p else None


def decode(path):
    s = open(path, errors="ignore").read()
    b1 = first_part_after(s, 1)
    if b1 is None:
        return None
    b2 = first_part_after(s, 2) or 0
    return {
        "name": os.path.basename(path)[:-4],
        "b1": b1, "b2": b2,
        "id": ((b2 & 0x07) << 3) | (((b1 >> 5) & 1) << 2) | ((b1 >> 6) & 3),
        "zone": (b1 >> 3) & 3,
        "visarea": b1 & 3,
        "extend": (b1 >> 2) & 1,
        "pal12": (b2 >> 5) & 1,
        "map": (b2 >> 4) & 1,
        "uart": (b2 >> 6) & 3,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    files = sorted(glob.glob("releases/*.mra")) + sorted(
        glob.glob("releases/experimental/*.mra"))
    rows = [r for r in (decode(f) for f in files) if r]
    if not rows:
        sys.exit("no MRAs found -- run from the repository root")

    if not args.quiet:
        hdr = ("game", "b1", "b2", "id", "zn", "vis", "ext", "p12", "map", "uart")
        print(f"{hdr[0]:<34}{hdr[1]:>4}{hdr[2]:>4}{hdr[3]:>4}{hdr[4]:>3}"
              f"{hdr[5]:>4}{hdr[6]:>4}{hdr[7]:>4}{hdr[8]:>4}{hdr[9]:>5}")
        for r in rows:
            print(f"{r['name']:<34}{r['b1']:>4x}{r['b2']:>4x}{r['id']:>4}"
                  f"{r['zone']:>3}{r['visarea']:>4}{r['extend']:>4}"
                  f"{r['pal12']:>4}{r['map']:>4}{r['uart']:>5}")
        print()

    fail = []

    # 1. Two different games must never share a game id -- that is the failure
    #    that put Land Maker's config on Riding Fight's rendering path.
    by_id = collections.defaultdict(list)
    for r in rows:
        by_id[r["id"]].append(r["name"])
    for gid, names in sorted(by_id.items()):
        bases = {VARIANT.sub("", n).strip() for n in names}
        if len(bases) > 1:
            fail.append(f"game id {gid} shared by different games: {names}")

    # 2. Release rule 4: no shipping MRA injects a start zone.
    for r in rows:
        if r["zone"] and "(zone 2)" not in r["name"]:
            fail.append(f"{r['name']}: starts at zone {r['zone']}, "
                        "release rule 4 allows this only in a (zone 2) file")

    # 3. Release rule 3-adjacent: a shipping MRA must not pin the UART to a
    #    debug stream, which also overrides the OSD.
    for r in rows:
        if r["uart"] and not VARIANT.search(r["name"]):
            fail.append(f"{r['name']}: pins UART mode {r['uart']}, "
                        "which overrides the OSD for a non-debug MRA")

    # 4. The pal12 bit is an override; the RTL id table is the normal path.
    #    A game in the table with the bit also set is harmless but means the
    #    two sources disagree about who owns the decision.
    for r in rows:
        if r["pal12"] and r["id"] in PAL12_BY_ID:
            fail.append(f"{r['name']}: pal12 set in the MRA and in the RTL id "
                        "table; pick one owner")
        if r["pal12"] and r["id"] not in PAL12_BY_ID:
            print(f"note: {r['name']} forces 12-bit palette from the MRA "
                  "only -- deliberate?")

    ids = sorted(by_id)
    print(f"{len(rows)} MRAs, {len(ids)} distinct game ids, "
          f"{sum(r['map'] for r in rows)} on map profile 1")
    if fail:
        print("\nFAIL")
        for f in fail:
            print("  " + f)
        return 1
    print("all config-byte checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
