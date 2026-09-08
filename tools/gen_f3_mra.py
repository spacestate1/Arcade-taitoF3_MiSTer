#!/usr/bin/env python3
"""Regenerate the F3 MRAs that were built from a spec rather than by hand.

    python3 tools/gen_f3_mra.py          # write releases/experimental/*.mra
    F3_ROMS=/path/to/mame python3 tools/gen_f3_mra.py

WHY THIS EXISTS. Eight MRAs were added in one go on 2026-09-08, and an MRA
is mostly arithmetic: each of the seven regions has a fixed slot in the
universal 18.5 MB map, and the ROMs have to be padded up to it. Typing those
pad lengths by hand is how a region ends up a megabyte short, and the only
symptom is a game that renders wrong. Here the pads are COMPUTED from the
real file sizes in the zip, so a region cannot come out the wrong length.

The gate is still tools/rf_stream_sum.py: if the assembled stream is not
exactly 0x01280000 the spec is wrong, whatever this script believed.

    for m in releases/experimental/*.mra; do
      .venv/bin/python3 tools/rf_stream_sum.py "$m" $F3_ROMS/<set>.zip
    done

It REFUSES to overwrite an MRA whose <setname> does not match, because
deriving a filename from a display name once silently overwrote the existing
Darius Gaiden.mra with its Extra Version.

HAND-WRITTEN MRAs ARE NOT PRODUCED HERE and this script will not touch them:
Ray Force, Gunlock, Elevator Action Returns, the Bubble games, Puzzle Bobble
2, Darius Gaiden, Arkanoid Returns and Grid Seeker are all hand-written,
several because they need something this generator cannot express (Grid
Seeker's factory ROM patch, for one).
"""
import os
import sys
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "releases", "experimental")

SLOT = {"maincpu": 0x200000, "audiocpu": 0x80000, "sprites": 0x400000,
        "sprites_hi": 0x200000, "tilemap": 0x400000, "tilemap_hi": 0x200000,
        "ensoniq": 0x400000}
ROMDIR = os.environ.get("F3_ROMS", "/storage02/roms/mame")


def sizes(zf):
    return {i.filename: i.file_size for i in zf.infolist()}, \
           {i.filename: i.CRC & 0xFFFFFFFF for i in zf.infolist()}


def emit(game, spec, out):
    # A game may widen a region slot. Ensoniq is the LAST region in the map,
    # so a game using all 8 MB of it simply streams 4 MB more than the rest
    # and every earlier MRA is untouched -- which is the whole reason the
    # region was grown there rather than in the middle.
    # "--" is ILLEGAL inside an XML comment and every note here lands in one.
    # This has broken an MRA twice by hand, and the failure is silent until
    # something tries to parse it, so sanitise rather than remember.
    game = dict(game)
    game["note"] = game["note"].replace("--", "-")

    slots = dict(SLOT)
    for k, v in game.get("slots", {}).items():
        slots[k] = v
    zf = zipfile.ZipFile(f"{ROMDIR}/{game['set']}.zip")
    sz, crc = sizes(zf)

    def find(n):
        if n in sz:
            return n
        for k in sz:
            if k.endswith("/" + n) or k == n:
                return k
        raise SystemExit(f"{game['set']}: part {n} not in zip")

    lines = []
    total = 0
    for region, slot in slots.items():
        blocks = spec.get(region, [])
        lines.append(f"\n    <!-- {region} -->" if blocks else
                     f"\n    <!-- {region}: no ROM in this set -->")
        used = 0
        for b in blocks:
            kind = b[0]
            if kind == "il16":
                names = [find(x) for x in b[1]]
                for n, m in zip(names, ("01", "10")):
                    pass
                lines.append('    <interleave output="16">')
                for n, m in zip(names, ("01", "10")):
                    lines.append(f'      <part name="{n}" crc="{crc[n]:08x}" map="{m}"/>')
                lines.append("    </interleave>")
                used += sum(sz[n] for n in names)
            elif kind == "il32":
                names = [find(x) for x in b[1]]
                lines.append('    <interleave output="32">')
                for n, m in zip(names, ("0001", "0010", "0100", "1000")):
                    lines.append(f'      <part name="{n}" crc="{crc[n]:08x}" map="{m}"/>')
                lines.append("    </interleave>")
                used += sum(sz[n] for n in names)
            elif kind == "il32w":
                names = [find(x) for x in b[1]]
                lines.append('    <interleave output="32">')
                for n, m in zip(names, ("0021", "2100")):
                    lines.append(f'      <part name="{n}" crc="{crc[n]:08x}" map="{m}"/>')
                lines.append("    </interleave>")
                used += sum(sz[n] for n in names)
            elif kind == "raw":
                n = find(b[1])
                lines.append(f'    <part name="{n}" crc="{crc[n]:08x}"/>')
                used += sz[n]
            elif kind == "pad":
                lines.append(f'    <!-- {b[2].replace("--", "-")} -->')
                lines.append(f'    <part repeat="{b[1]}">00</part>')
                used += b[1]
            else:
                raise SystemExit("bad block " + kind)
        if used > slot:
            raise SystemExit(f"{game['set']}: {region} is {used:#x}, slot is {slot:#x}")
        if used < slot:
            lines.append(f'    <!-- pad {region} to {slot // 1024} KB -->')
            lines.append(f'    <part repeat="{slot - used}">00</part>')
        total += slot

    body = "\n".join(lines)
    xml = f"""<misterromdescription>
  <name>{game['name']}</name>
  <setname>{game['set']}</setname>
  <year>{game['year']}</year>
  <manufacturer>Taito</manufacturer>
  <rbf>Rayforce</rbf>
  <players>2</players>
  <joystick>8-way</joystick>
  <rotation>{game['rot']}</rotation>
  <region>World</region>

  <!-- ============================================================
       NEVER LOADED ON A BOARD. Written 2026-09-08.

       Taito F3, the same board Ray Force runs on. {game['note']}

       Region pads are computed from the real ROM sizes, and the
       assembled stream is 0x01280000 bytes (18.5 MB) exactly, which
       is what proves the regions land on the RTL's base addresses.
       ============================================================ -->
  <rom index="0" zip="{game['set']}.zip" md5="None">
{body}
  </rom>

  <!-- Game config (Rayforce.sv "GAME CONFIG"):
         index 1 = 0x{game['cfg1']:02X}, index 2 = 0x{game['cfg2']:02X}
           visarea {game['vis']}, extend {game['ext']}, zone injector off
           (so it starts on level 1), game id {game['id']}.
         No expectations are measured for this set yet, so it lands on
         the case default in Rayforce.sv and the ROM CHECKSUM / SDRAM
         BIST / WRITE HASH rows REPORT what they find rather than
         failing against another game's numbers. The self-test TITLE
         row clamps (rf_selftest.sv:329) until a build gives this game
         its own row. That is the page, not the game. -->
  <rom index="1">
    <part>{game['cfg1']:02X}</part>
  </rom>
  <rom index="2">
    <part>{game['cfg2']:02X}</part>
  </rom>

  <!-- the 93C46 settings EEPROM: 64 words, saved to config/nvram/<mra>.nvm -->
  <nvram index="254" size="256"/>

  <buttons names="{game['btn']}" default="A,B,R,L,Select,Start" count="2"/>
</misterromdescription>
"""
    open(out, "w").write(xml)
    print(f"wrote {out}")


P12 = "A 12-BIT PALETTE GAME. MAME stores this set's colours as RRRRGGGGBBBB0000 in the low word and scales each nibble by 16, selected by game rather than by register (taito_f3_v.cpp palette_24bit_w). The core does the same, from the game id, and MRA index 2 bit [5] also turns it on. "
SPARSE = 'Its ensoniq banks are sparse: the first ROM fills banks 0 and 1, bank 2 is empty, and the second sits in bank 3 (MAME offset 0x600000), so the hole is padded to land bank 3 on its boundary. Its sound ROM is half size and is streamed TWICE, because taito_en maps a 0x140000 region as set_entry(i % 2) = 0,1,0 and this core maps that window linearly.'
MIRROR = "sound ROM is half size; streamed TWICE so the third bank window reads bank 0, which is what taito_en's set_entry(i % max) does with a 0x140000 region"

GAMES = [
 (dict(set="spcinv95", name="Space Invaders '95 - Attack of the Lunar Loonies", year="1995",
       rot="vertical", cfg1=0x24, cfg2=0x01, vis=0, ext=0, id=12,
       btn="Shot,Bomb,-,-,-,-,Start,Coin,Service,Pause",
       note="A VERTICAL game (MAME ROT270), so Rotate CW or CCW in the OSD. extend=0, as Puzzle Bobble 2."),
  {"maincpu":[("il32",["e06-14.20","e06-13.19","e06-12.18","e06-16.17"])],
   "audiocpu":[("il16",["e06-09.32","e06-10.33"])],
   "sprites":[("il16",["e06-03","e06-02"])],
   "sprites_hi":[("raw","e06-01")],
   "tilemap":[("il32w",["e06-08","e06-07"])],
   "tilemap_hi":[("raw","e06-06")],
   "ensoniq":[("raw","e06-04"),("raw","e06-05")]}),

 (dict(set="cleopatr", name="Cleopatra Fortune", year="1996",
       rot="horizontal", cfg1=0x64, cfg2=0x01, vis=0, ext=0, id=13,
       btn="Rotate,Drop,-,-,-,-,Start,Coin,Service,Pause",
       note="Horizontal (MAME ROT0), so Rotate None. extend=0. Its "+MIRROR+". Its ensoniq region is 4 MB, so MAME's otisbank mask is 1 where the core uses 3 until the next build."),
  {"maincpu":[("il32",["e28-10.bin","e28-09.bin","e28-08.bin","e28-07.bin"])],
   "audiocpu":[("il16",["e28-11.bin","e28-12.bin"]),("il16",["e28-11.bin","e28-12.bin"])],
   "sprites":[("il16",["e28-02.bin","e28-01.bin"])],
   "sprites_hi":[],
   "tilemap":[("il32w",["e28-06.bin","e28-05.bin"])],
   "tilemap_hi":[("raw","e28-04.bin")],
   "ensoniq":[("raw","e28-03.bin")]}),

 (dict(set="twinqix", name="Twin Qix", year="1995",
       rot="horizontal", cfg1=0xA0, cfg2=0x01, vis=0, ext=1, id=14,
       btn="Button 1,Button 2,-,-,-,-,Start,Coin,Service,Pause",
       note="Horizontal (MAME ROT0). Note its tilemap is a ROM_LOAD32_BYTE x4 and its tilemap_hi a ROM_LOAD16_BYTE pair, where most F3 sets use a LOAD32_WORD pair and a single ROM. Its ensoniq region is 4 MB, so MAME's otisbank mask is 1."),
  {"maincpu":[("il32",["mpr0-3.b60","mpr0-2.b61","mpr0-1.b62","mpr0-0.b63"])],
   "audiocpu":[("il16",["spr0-1.b66","spr0-0.b65"])],
   "sprites":[("il16",["obj0-0.a08","obj0-1.a20"])],
   "sprites_hi":[],
   "tilemap":[("il32",["scr0-0.b07","scr0-1.b06","scr0-2.b05","scr0-3.b04"])],
   "tilemap_hi":[("il16",["scr0-4.b03","scr0-5.b02"])],
   "ensoniq":[("raw","snd-0.b43"),("raw","snd-1.b44"),("raw","snd-14.b10"),("raw","snd-15.b11")]}),

 (dict(set="recalh", name="Recalhorn", year="1994",
       rot="horizontal", cfg1=0xE3, cfg2=0x01, vis=3, ext=1, id=15,
       btn="Jump,Attack,-,-,-,-,Start,Coin,Service,Pause",
       note="An UNRELEASED prototype. Horizontal (MAME ROT0). Its "+MIRROR+". Its ensoniq banks are sparse: rh_snd0 fills banks 0 and 1, bank 2 is empty, rh_snd1 sits in bank 3 (MAME offset 0x600000), so the hole is padded to put bank 3 on its boundary."),
  {"maincpu":[("il32",["rh_mpr3.bin","rh_mpr2.bin","rh_mpr1.bin","rh_mpr0.bin"])],
   "audiocpu":[("il16",["rh_spr1.bin","rh_spr0.bin"]),("il16",["rh_spr1.bin","rh_spr0.bin"])],
   "sprites":[("il16",["rh_objl.bin","rh_objm.bin"])],
   "sprites_hi":[],
   "tilemap":[("il32w",["rh_scrl.bin","rh_scrm.bin"])],
   "tilemap_hi":[],
   "ensoniq":[("raw","rh_snd0.bin"),("pad",0x100000,"ensoniq bank 2 is empty in MAME"),("raw","rh_snd1.bin")]}),

 (dict(set="qtheater", name="Quiz Theater - 3tsu no Monogatari", year="1994",
       rot="horizontal", cfg1=0x02, cfg2=0x02, vis=2, ext=1, id=16,
       btn="Button 1,Button 2,-,-,-,-,Start,Coin,Service,Pause",
       note="Horizontal (MAME ROT0). This is the ONLY set here using visarea f3_224c (224 lines from line 24); the core implements all four crops."),
  {"maincpu":[("il32",["d95-12.20","d95-11.19","d95-10.18","d95-09.17"])],
   "audiocpu":[("il16",["d95-07.32","d95-08.33"])],
   "sprites":[("il16",["d95-02.12","d95-01.8"])],
   "sprites_hi":[],
   "tilemap":[("il32w",["d95-06.47","d95-05.45"])],
   "tilemap_hi":[],
   "ensoniq":[("raw","d95-03.38"),("raw","d95-04.41")]}),

 (dict(set="popnpop", name="Pop 'n Pop", year="1997",
       rot="horizontal", cfg1=0x43, cfg2=0x02, vis=3, ext=1, id=17,
       btn="Shot,Button 2,-,-,-,-,Start,Coin,Service,Pause",
       note="Horizontal (MAME ROT0)."),
  {"maincpu":[("il32",["e51-12.20","e51-11.19","e51-10.18","e51-16.17"])],
   "audiocpu":[("il16",["e51-13.32","e51-14.33"])],
   "sprites":[("il16",["e51-03.12","e51-02.8"])],
   "sprites_hi":[("raw","e51-01.4")],
   "tilemap":[("il32w",["e51-08.47","e51-07.45"])],
   "tilemap_hi":[("raw","e51-06.43")],
   "ensoniq":[("raw","e51-04.38"),("raw","e51-05.41")]}),

 (dict(set="gekiridn", name="Gekirindan", year="1995",
       rot="vertical", cfg1=0x87, cfg2=0x02, vis=3, ext=0, id=18,
       btn="Shot,Bomb,-,-,-,-,Start,Coin,Service,Pause",
       note="A VERTICAL game (MAME ROT270), so Rotate CW or CCW in the OSD. extend=0. It fills every region of the map exactly, with no padding at all."),
  {"maincpu":[("il32",["e11-12.ic20","e11-11.ic19","e11-10.ic18","e11-15.ic17"])],
   "audiocpu":[("il16",["e11-13.ic32","e11-14.ic33"])],
   "sprites":[("il16",["e11-03.ic12","e11-02.ic8"])],
   "sprites_hi":[("raw","e11-01.ic4")],
   "tilemap":[("il32w",["e11-08.ic47","e11-07.ic45"])],
   "tilemap_hi":[("raw","e11-06.ic43")],
   "ensoniq":[("raw","e11-04.ic38"),("raw","e11-05.ic41")]}),

 (dict(set="dariusgx", name="Darius Gaiden - Silver Hawk (Extra Version)", year="1994",
       rot="horizontal", cfg1=0xC7, cfg2=0x02, vis=3, ext=0, id=19,
       btn="Shot,Bomb,-,-,-,-,Start,Coin,Service,Pause",
       note="The Extra Version of Darius Gaiden, which already runs here. Horizontal (MAME ROT0), extend=0. Like the parent it uses the pixel (pivot) layer, which this core only MIRRORS as an 8 KB window, so expect the same rendering gap the parent has."),
  {"maincpu":[("il32",["dge_mpr3.bin","dge_mpr2.bin","dge_mpr1.bin","dge_mpr0.bin"])],
   "audiocpu":[("il16",["d87-13.bin","d87-14.bin"])],
   "sprites":[("il16",["d87-03.bin","d87-04.bin"])],
   "sprites_hi":[("raw","d87-05.bin")],
   "tilemap":[("il32w",["d87-06.bin","d87-17.bin"])],
   "tilemap_hi":[("raw","d87-08.bin")],
   "ensoniq":[("raw","d87-01.bin"),("raw","d87-02.bin")]}),
(dict(set="pbobble3", name="Puzzle Bobble 3", year="1996",
       rot="horizontal", cfg1=0x47, cfg2=0x01, vis=3, ext=0, id=9,
       slots={"ensoniq": 0x800000},
       btn="Shoot,-,-,-,-,-,Start,Coin,Service,Pause",
       note=("Horizontal (MAME ROT0), extend=0 as Puzzle Bobble 2. THE FIRST "
             "SETS TO USE THE WHOLE 8 MB ENSONIQ REGION, so this MRA streams "
             "22.5 MB where every earlier one streams 18.5. MAME gives them a "
             "16 MB sample region against Ray Force's 8, which makes taito_en's "
             "otisbank mask 7 rather than 3 -- three bank bits, not two. That "
             "one bit is the whole reason these games did not run before; they "
             "never needed a bigger MAP, only a wider bank. Bank 0 is empty in "
             "MAME and is padded here so banks 1-3 land on their boundaries.")),
  {"maincpu":[("il32",["e29-12.rom","e29-11.rom","e29-10.rom","e29-16.rom"])],
   "audiocpu":[("il16",["e29-13.rom","e29-14.rom"])],
   "sprites":[("il16",["e29-02.rom","e29-01.rom"])],
   "sprites_hi":[],
   "tilemap":[("il32w",["e29-08.rom","e29-07.rom"])],
   "tilemap_hi":[("raw","e29-06.rom")],
   "ensoniq":[("pad",0x200000,"ensoniq bank 0 is empty in MAME"),
              ("raw","e29-03.rom"),("raw","e29-04.rom"),("raw","e29-05.rom")]}),

 (dict(set="pbobble4", name="Puzzle Bobble 4", year="1997",
       rot="horizontal", cfg1=0x87, cfg2=0x01, vis=3, ext=0, id=10,
       slots={"ensoniq": 0x800000},
       btn="Shoot,-,-,-,-,-,Start,Coin,Service,Pause",
       note="Horizontal (MAME ROT0), extend=0. Same 16 MB sample region and 3-bit otisbank mask as Puzzle Bobble 3; see that MRA for the detail. Streams 22.5 MB.",
       ),
  {"maincpu":[("il32",["e49-12.20","e49-11.19","e49-10.18","e49-16.17"])],
   "audiocpu":[("il16",["e49-13.32","e49-14.33"])],
   "sprites":[("il16",["e49-02","e49-01"])],
   "sprites_hi":[],
   "tilemap":[("il32w",["e49-08","e49-07"])],
   "tilemap_hi":[("raw","e49-06")],
   "ensoniq":[("pad",0x200000,"ensoniq bank 0 is empty in MAME"),
              ("raw","e49-03"),("raw","e49-04"),("raw","e49-05")]}),
(dict(set="arabianm", name="Arabian Magic", year="1992",
       rot="horizontal", cfg1=0x24, cfg2=0x02, vis=0, ext=0, id=20,
       btn="Attack,Jump,-,-,-,-,Start,Coin,Service,Pause",
       note=P12 + "Horizontal (MAME ROT0), extend=0. " + SPARSE),
  {"maincpu":[("il32",["d29-23.ic40","d29-22.ic38","d29-21.ic36","d29-25.ic34"])],
   "audiocpu":[("il16",["d29-18.ic5","d29-19.ic6"]),("il16",["d29-18.ic5","d29-19.ic6"])],
   "sprites":[("il16",["d29-03.ic66","d29-04.ic67"])],
   "sprites_hi":[("raw","d29-05.ic68")],
   "tilemap":[("il32w",["d29-06.ic49","d29-07.ic50"])],
   "tilemap_hi":[("raw","d29-08.ic51")],
   "ensoniq":[("raw","d29-01.ic17"),("pad",0x100000,"ensoniq bank 2 is empty in MAME"),("raw","d29-02.ic18")]}),

 (dict(set="ridingf", name="Riding Fight", year="1992",
       rot="horizontal", cfg1=0x61, cfg2=0x02, vis=1, ext=1, id=21,
       btn="Attack,Jump,-,-,-,-,Start,Coin,Service,Pause",
       note=P12 + "Horizontal (MAME ROT0), visarea f3_224b. It has NEITHER a sprites_hi NOR a tilemap_hi ROM, so both regions are zeros. " + SPARSE),
  {"maincpu":[("il32",["d34-12.40","d34-11.38","d34-10.36","d34_14.34"])],
   "audiocpu":[("il16",["d34-07.5","d34-08.6"]),("il16",["d34-07.5","d34-08.6"])],
   "sprites":[("il16",["d34-01.66","d34-02.67"])],
   "sprites_hi":[],
   "tilemap":[("il32w",["d34-05.49","d34-06.50"])],
   "tilemap_hi":[],
   "ensoniq":[("raw","d34-03.17"),("pad",0x100000,"ensoniq bank 2 is empty in MAME"),("raw","d34-04.18")]}),

 (dict(set="ringrage", name="Ring Rage", year="1992",
       rot="horizontal", cfg1=0xA4, cfg2=0x02, vis=0, ext=0, id=22,
       btn="Punch,Kick,-,-,-,-,Start,Coin,Service,Pause",
       note=P12 + "Horizontal (MAME ROT0), extend=0. " + SPARSE),
  {"maincpu":[("il32",["d21-23.40","d21-22.38","d21-21.36","d21-25.34"])],
   "audiocpu":[("il16",["d21-18.5","d21-19.6"]),("il16",["d21-18.5","d21-19.6"])],
   "sprites":[("il16",["d21-02.66","d21-03.67"])],
   "sprites_hi":[("raw","d21-04.68")],
   "tilemap":[("il32w",["d21-06.49","d21-07.50"])],
   "tilemap_hi":[("raw","d21-08.51")],
   "ensoniq":[("raw","d21-01.17"),("pad",0x100000,"ensoniq bank 2 is empty in MAME"),("raw","d21-05.18")]}),
]

# explicit filenames: deriving one from the display name silently overwrote
# the existing Darius Gaiden.mra, whose Extra Version shares its prefix
FILE = {"spcinv95": "Space Invaders '95", "cleopatr": "Cleopatra Fortune",
        "twinqix": "Twin Qix", "recalh": "Recalhorn", "qtheater": "Quiz Theater",
        "popnpop": "Pop 'n Pop", "gekiridn": "Gekirindan",
        "dariusgx": "Darius Gaiden Extra Version",
        "pbobble3": "Puzzle Bobble 3", "pbobble4": "Puzzle Bobble 4",
        "arabianm": "Arabian Magic", "ridingf": "Riding Fight",
        "ringrage": "Ring Rage"}

def target(g):
    return os.path.join(OUT, FILE[g["set"]] + ".mra")


def setname_of(path):
    """The <setname> already in a file, or None if there is no file."""
    if not os.path.exists(path):
        return None
    for line in open(path, encoding="utf-8", errors="ignore"):
        if "<setname>" in line:
            return line.split("<setname>")[1].split("<")[0].strip()
    return ""


if __name__ == "__main__":
    # PRE-FLIGHT EVERY TARGET BEFORE WRITING ANY. Checking as we go left
    # seven files rewritten and the eighth refused, which is a worse state
    # than either doing all of it or none of it.
    clash = [(target(g), setname_of(target(g)), g["set"])
             for g, _ in GAMES
             if setname_of(target(g)) not in (None, g["set"])]
    if clash:
        for path, found, want in clash:
            print(f"REFUSING: {path} holds set '{found}', not '{want}'", file=sys.stderr)
        raise SystemExit("nothing written")

    for g, spec in GAMES:
        emit(g, spec, target(g))
