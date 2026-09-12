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

# SDRAM map profile 0: the layout every game before 2026-09-08 uses. Ensoniq
# is 8 MB in the RTL but a game that only fills 4 MB simply streams less --
# it is the last region, so nothing moves.
SLOT = {"maincpu": 0x200000, "audiocpu": 0x80000, "sprites": 0x400000,
        "sprites_hi": 0x200000, "tilemap": 0x400000, "tilemap_hi": 0x200000,
        "ensoniq": 0x400000}

# Profile 1 (cfg_map = 1, MRA index 2 bit [4]): 42 MB, for the fourteen sets
# that do not fit profile 0. sprites_hi is 7 MB and tilemap_hi 3 MB because
# Kaiser Knuckle needs 6.5 and 3 -- both regions are filled only by plain
# ROM_LOAD, which is exactly what the first sizing script failed to match,
# and it made this layout 36 MB and too small. See F3-LIBRARY.md.
SLOT1 = {"maincpu": 0x200000, "audiocpu": 0x300000, "sprites": 0xD00000,
         "sprites_hi": 0x700000, "tilemap": 0x600000, "tilemap_hi": 0x300000,
         "ensoniq": 0x800000}
ROMDIR = os.environ.get("F3_ROMS", "/storage02/roms/mame")


def sizes(zf):
    return {i.filename: i.file_size for i in zf.infolist()}, \
           {i.filename: i.CRC & 0xFFFFFFFF for i in zf.infolist()}


def cfg_bytes(game):
    """Compute the two MRA config bytes from id / vis / extend / map.

    THESE WERE HAND-COMPUTED ONCE AND NINE OF THIRTEEN WERE WRONG. The id is
    split {index2[2:0], index1[5], index1[7:6]}, which is easy to get right
    for ids under 8 and easy to get wrong above -- Land Maker's 23 came out
    as 21, colliding with Riding Fight, and Top Ranking Stars' 28 as 22,
    colliding with Ring Rage. Worse, every profile-1 set had cfg_map clear,
    so the MRA laid its regions out for the 42 MB map while the core read
    them at 18.5 MB addresses. Nothing catches that but the screen.

    Verified against four MRAs known to work on hardware: Gekirindan 0x87/
    0x02, Grid Seeker 0xC5/0x01, Arkanoid Returns 0x03/0x01 and Puzzle
    Bobble 3 0x47/0x01.
    """
    i = game["id"]
    idx1 = ((game["vis"] & 3)
            | ((0 if game["ext"] else 1) << 2)   # bit 2 asks for NON-extend
            | (((i >> 2) & 1) << 5)
            | ((i & 3) << 6))
    idx2 = (((i >> 3) & 7)
            | (game.get("map", 0) << 4)          # cfg_map: the 42 MB profile
            | (game.get("pal12", 0) << 5))       # 12-bit palette override
    assert (((idx2 & 7) << 3) | (((idx1 >> 5) & 1) << 2) | ((idx1 >> 6) & 3)) == i
    return idx1, idx2



# ---- pad defaults ---------------------------------------------------------
# The bench pad's layout, read back off the board from
# config/inputs/rayforce_input_045e_02d1_v3.map on 2026-09-11 and made the
# default for the whole library: button 1 = A, button 2 = B, Start = Start,
# Coin = R (right shoulder), Service = Select, Pause = L (left shoulder).
# Extra game buttons take X then Y then the shoulders, in that order.
#
# An MRA default may only name A B X Y L R Start Select and "-" -- the
# triggers are NOT addressable here (surveyed across 394 MRAs on the board),
# so a 6-button game, which needs all four faces AND both shoulders, has
# nothing left for Coin and Pause. Those two fall back to Select and to
# nothing; both are reachable from the OSD. The fighters therefore use the
# standard arcade layout instead of this one -- LP/MP/HP over LK/MK/HK --
# because on a 6-button game the physical arrangement is the point.
PAD_ORDER = ["A", "B", "X", "Y", "L", "R"]
FIGHTER   = "Y,X,L,B,A,R,Start,Select,-"

def btn_count(btn):
    """Game buttons to expose: the named ones, but never fewer than two.

    The floor is FOUR, and it is the important part. MAME wires four buttons
    into IN.0 for every F3 game in the driver (audited across all 26 sets,
    2026-09-11) and rf_main already drives all four from joystick bits 4-7 --
    so the hardware path has always been there and only the MRA hid it.
    Shipping count="2" is exactly why Arabian Magic's "Magic" and Command
    War's third button did nothing when they were played, and neither game
    was in any way special. A game that ignores button 3 or 4 simply ignores
    it, so exposing them costs nothing and guessing per game costs plenty.
    Raising a count is safe; lowering one takes a working button away from
    whoever had mapped it.
    """
    named = sum(1 for x in btn.split(",")[:6] if x.strip() not in ("-", ""))
    return max(named, 4)

def btn_default(n):
    if n >= 6:
        return FIGHTER
    return ",".join(PAD_ORDER[:n] + ["Start", "R", "Select", "L"])


def btn_names(btn, n):
    """Make sure the first n slots are labelled -- an exposed button that
    shows as "-" in the mapping menu looks broken rather than generic."""
    parts = [x.strip() for x in btn.split(",")]
    for i in range(min(n, 6)):
        if parts[i] in ("-", ""):
            parts[i] = f"Button {i+1}"
    return ",".join(parts)

def emit(game, spec, out):
    game = dict(game)
    game["cfg1"], game["cfg2"] = cfg_bytes(game)
    # count and pad defaults follow the button NAMES, so a game that gains a
    # button only has to gain a name
    game.setdefault("btnc", btn_count(game["btn"]))
    game.setdefault("btnd", btn_default(game["btnc"]))
    game["btn"] = btn_names(game["btn"], game["btnc"])
    # A game may widen a region slot. Ensoniq is the LAST region in the map,
    # so a game using all 8 MB of it simply streams 4 MB more than the rest
    # and every earlier MRA is untouched -- which is the whole reason the
    # region was grown there rather than in the middle.
    # "--" is ILLEGAL inside an XML comment and every note here lands in one.
    # This has broken an MRA twice by hand, and the failure is silent until
    # something tries to parse it, so sanitise rather than remember.
    game = dict(game)
    game["note"] = game["note"].replace("--", "-")

    slots = dict(SLOT1 if game.get("map") == 1 else SLOT)
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

  <buttons names="{game['btn']}" default="{game.get('btnd', 'A,B,R,L,Select,Start')}" count="{game.get('btnc', 2)}"/>
</misterromdescription>
"""
    open(out, "w").write(xml)
    print(f"wrote {out}")


SP = ("Its ensoniq banks are sparse: the first ROM fills banks 0 and 1, bank 2 is "
      "empty, and the second sits in bank 3 (MAME offset 0x600000), so the hole is "
      "padded to land bank 3 on its boundary.")
E16 = "Its ensoniq region is 16 MB in MAME, so taito_en's otisbank mask is 7 -- three bank bits, like Puzzle Bobble 3/4 -- and bank 0 is empty, so it is padded to land the samples on their boundaries. "
MIR = ("Its sound ROM is half size and is streamed TWICE, because taito_en maps a "
       "0x140000 region as set_entry(i % 2) = 0,1,0 and this core maps that window "
       "linearly; zero padding would put silence where the game expects code.")
P1N = ("USES SDRAM MAP PROFILE 1 (index 2 bit [4]), the 42 MB layout, because its "
       "sprites do not fit profile 0's 4 MB. Profile 1 gives sprites 13 MB, "
       "sprites_hi 7 MB, tilemap 6 MB and tilemap_hi 3 MB. ")
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
       btn="Attack,Jump,Magic,-,-,-,Start,Coin,Service,Pause",
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
       btn="Button 1,Button 2,Button 3,Button 4,-,-,Start,Coin,Service,Pause",
       note=P12 + "Horizontal (MAME ROT0), extend=0. " + SPARSE),
  {"maincpu":[("il32",["d21-23.40","d21-22.38","d21-21.36","d21-25.34"])],
   "audiocpu":[("il16",["d21-18.5","d21-19.6"]),("il16",["d21-18.5","d21-19.6"])],
   "sprites":[("il16",["d21-02.66","d21-03.67"])],
   "sprites_hi":[("raw","d21-04.68")],
   "tilemap":[("il32w",["d21-06.49","d21-07.50"])],
   "tilemap_hi":[("raw","d21-08.51")],
   "ensoniq":[("raw","d21-01.17"),("pad",0x100000,"ensoniq bank 2 is empty in MAME"),("raw","d21-05.18")]}),
(dict(set="landmakr", name="Land Maker", year="1998",
       rot="horizontal", cfg1=0x63, cfg2=0x02, vis=3, ext=1, id=23,
       slots={"ensoniq": 0x800000},
       btn="Button 1,Button 2,-,-,-,-,Start,Coin,Service,Pause",
       note=("Horizontal (MAME ROT0). It fits PROFILE 0 -- it was listed as blocked on "
             "ensoniq, and stopped being so when that region grew 4 MB to 8 MB for "
             "Puzzle Bobble 3/4. Its region is 16 MB in MAME, so the otisbank mask is "
             "7 and it needs three bank bits, like those two. Banks 1-3 hold the "
             "samples and bank 0 is empty, so the hole is padded.")),
  {"maincpu":[("il32",["e61-19.20","e61-18.19","e61-17.18","e61-16.17"])],
   "audiocpu":[("il16",["e61-14.32","e61-15.33"])],
   "sprites":[("il16",["e61-03.12","e61-02.08"])],
   "sprites_hi":[("raw","e61-01.04")],
   "tilemap":[("il32w",["e61-09.47","e61-08.45"])],
   "tilemap_hi":[("raw","e61-07.43")],
   "ensoniq":[("pad",0x200000,"ensoniq bank 0 is empty in MAME"),
              ("raw","e61-04.38"),("raw","e61-05.39"),("raw","e61-06.40")]}),

 (dict(set="trstar", name="Top Ranking Stars", year="1993", map=1,
       rot="horizontal", cfg1=0xA3, cfg2=0x02, vis=3, ext=1, id=28,
       btn="Button 1,Button 2,Button 3,Button 4,-,-,Start,Coin,Service,Pause",
       note=P1N + "Horizontal (MAME ROT0). " + MIR + " " + SP),
  {"maincpu":[("il32",["d53-15-1.24","d53-16-1.26","d53-18-1.37","d53-20-1.35"])],
   "audiocpu":[("il16",["d53-13.10","d53-14.23"]),("il16",["d53-13.10","d53-14.23"])],
   "sprites":[("il16",["d53-03.45","d53-04.46"]),("il16",["d53-06.64","d53-07.65"])],
   "sprites_hi":[("raw","d53-05.47"),("raw","d53-08.66")],
   "tilemap":[("il32w",["d53-09.48","d53-10.49"])],
   "tilemap_hi":[("raw","d53-11.50")],
   "ensoniq":[("raw","d53-01.2"),("raw","d53-02.3")]}),

 (dict(set="cupfinal", name="Taito Cup Finals", year="1993", map=1,
       rot="horizontal", cfg1=0x03, cfg2=0x03, vis=3, ext=1, id=24,
       btn="Shoot,Pass,-,-,-,-,Start,Coin,Service,Pause",
       note=P1N + "Horizontal (MAME ROT0). Known as Hattrick Hero '93 in Japan. " + MIR + " " + SP),
  {"maincpu":[("il32",["d49-13.20","d49-14.19","d49-16.18","d49-20.17"])],
   "audiocpu":[("il16",["d49-17.32","d49-18.33"]),("il16",["d49-17.32","d49-18.33"])],
   "sprites":[("il16",["d49-01.12","d49-02.8"]),("il16",["d49-06.11","d49-07.7"])],
   "sprites_hi":[("raw","d49-03.4"),("raw","d49-08.3")],
   "tilemap":[("il32w",["d49-09.47","d49-10.45"])],
   "tilemap_hi":[("raw","d49-11.43")],
   "ensoniq":[("raw","d49-04.38"),("pad",0x100000,"ensoniq bank 2 is empty in MAME"),("raw","d49-05.41")]}),
(dict(set="intcup94", name="International Cup 94", year="1994", map=1,
       rot="horizontal", cfg1=0x43, cfg2=0x03, vis=3, ext=1, id=25,
       btn="Shoot,Pass,-,-,-,-,Start,Coin,Service,Pause",
       note=P1N + "Hattrick Hero '94 in Japan. It shares Taito Cup Finals' sprite and sample ROMs entirely; only the program and tilemaps differ. " + MIR + " " + SP),
  {"maincpu":[("il32",["d78-07.20","d78-06.19","d78-05.18","d78-11.17"])],
   "audiocpu":[("il16",["d78-08.32","d78-09.33"]),("il16",["d78-08.32","d78-09.33"])],
   "sprites":[("il16",["d49-01.12","d49-02.8"]),("il16",["d49-06.11","d49-07.7"])],
   "sprites_hi":[("raw","d49-03.4"),("raw","d49-08.3")],
   "tilemap":[("il32w",["d78-01.47","d78-02.45"])],
   "tilemap_hi":[("raw","d78-03.43")],
   "ensoniq":[("raw","d49-04.38"),("pad",0x100000,"ensoniq bank 2 is empty in MAME"),("raw","d49-05.41")]}),

 (dict(set="scfinals", name="Super Cup Finals", year="1993", map=1,
       rot="horizontal", cfg1=0x83, cfg2=0x03, vis=3, ext=1, id=26,
       btn="Shoot,Pass,-,-,-,-,Start,Coin,Service,Pause",
       note=P1N + "Horizontal (MAME ROT0). Shares Taito Cup Finals' graphics and samples. " + MIR + " " + SP),
  {"maincpu":[("il32",["d68-09.ic40","d68-10.ic38","d68-11.ic36","d68-12.ic34"])],
   "audiocpu":[("il16",["d49-17.ic5","d49-18.ic6"]),("il16",["d49-17.ic5","d49-18.ic6"])],
   "sprites":[("il16",["d49-01.12","d49-02.8"]),("il16",["d49-06.11","d49-07.7"])],
   "sprites_hi":[("raw","d49-03.4"),("raw","d49-08.3")],
   "tilemap":[("il32w",["d49-09.47","d49-10.45"])],
   "tilemap_hi":[("raw","d49-11.43")],
   "ensoniq":[("raw","d49-04.38"),("pad",0x100000,"ensoniq bank 2 is empty in MAME"),("raw","d49-05.41")]}),

 (dict(set="pwrgoal", name="Taito Power Goal", year="1994", map=1,
       rot="horizontal", cfg1=0xC3, cfg2=0x03, vis=3, ext=1, id=27,
       btn="Shoot,Pass,-,-,-,-,Start,Coin,Service,Pause",
       note=P1N + "Hattrick Hero '95 in Japan, and the largest sprite set of the football games at 12 MB across THREE interleaved pairs."),
  {"maincpu":[("il32",["d94-18.20","d94-17.19","d94-16.18","d94-22.17"])],
   "audiocpu":[("il16",["d94-19.bin","d94-20.bin"])],
   "sprites":[("il16",["d94-09.bin","d94-06.bin"]),("il16",["d94-08.bin","d94-05.bin"]),("il16",["d94-07.bin","d94-04.bin"])],
   "sprites_hi":[("raw","d94-03.bin"),("raw","d94-02.bin"),("raw","d94-01.bin")],
   "tilemap":[("il32w",["d94-14.bin","d94-13.bin"])],
   "tilemap_hi":[("raw","d94-12.bin")],
   "ensoniq":[("raw","d94-10.bin"),("raw","d94-11.bin")]}),

 (dict(set="commandw", name="Command War", year="1993", map=1,
       rot="horizontal", cfg1=0x01, cfg2=0x04, vis=1, ext=1, id=29,
       btn="Button 1,Button 2,-,-,-,-,Start,Coin,Service,Pause",
       note=P1N + "Horizontal (MAME ROT0), visarea f3_224b. A PROTOTYPE. " + MIR),
  {"maincpu":[("il32",["cw_mpr3.bin","cw_mpr2.bin","cw_mpr1.bin","cw_mpr0.bin"])],
   "audiocpu":[("il16",["cw_spr1.bin","cw_spr0.bin"]),("il16",["cw_spr1.bin","cw_spr0.bin"])],
   "sprites":[("il16",["cw_objl0.bin","cw_objm0.bin"]),("il16",["cw_objl1.bin","cw_objm1.bin"])],
   "sprites_hi":[("raw","cw_objh0.bin"),("raw","cw_objh1.bin")],
   "tilemap":[("il32w",["cw_scr_l.bin","cw_scr_m.bin"])],
   "tilemap_hi":[("raw","cw_scr_h.bin")],
   "ensoniq":[("raw","cw_pcm_0.bin"),("raw","cw_pcm_1.bin")]}),

 (dict(set="lightbr", name="Light Bringer", year="1993", map=1,
       rot="horizontal", cfg1=0x40, cfg2=0x04, vis=0, ext=1, id=30,
       btn="Attack,Jump,-,-,-,-,Start,Coin,Service,Pause",
       note=P1N + "Dungeon Magic outside Japan. Horizontal (MAME ROT0). " + MIR),
  {"maincpu":[("il32",["d69-25.ic40","d69-26.ic38","d69-28.ic36","d69-27.ic34"])],
   "audiocpu":[("il16",["d69-18.bin","d69-19.bin"]),("il16",["d69-18.bin","d69-19.bin"])],
   "sprites":[("il16",["d69-06.bin","d69-07.bin"]),("il16",["d69-09.bin","d69-10.bin"])],
   "sprites_hi":[("raw","d69-08.bin"),("raw","d69-11.bin")],
   "tilemap":[("il32w",["d69-03.bin","d69-04.bin"])],
   "tilemap_hi":[("raw","d69-05.bin")],
   "ensoniq":[("raw","d69-01.bin"),("raw","d69-02.bin")]}),

 (dict(set="tcobra2", name="Twin Cobra II", year="1995", map=1,
       rot="vertical", cfg1=0x83, cfg2=0x04, vis=3, ext=0, id=32,
       btn="Shot,Bomb,-,-,-,-,Start,Coin,Service,Pause",
       note=P1N + "A VERTICAL game (MAME ROT270), so Rotate CW or CCW in the OSD -- the only one of the fourteen that is. Kyukyoku Tiger II in Japan. It has NEITHER sprites_hi NOR tilemap_hi. " + MIR),
  {"maincpu":[("il32",["e15-14.ic20","e15-13.ic19","e15-12.ic18","e15-18.ic17"])],
   "audiocpu":[("il16",["e15-15.ic32","e15-16.ic33"]),("il16",["e15-15.ic32","e15-16.ic33"])],
   "sprites":[("il16",["e15-04.ic12","e15-02.ic8"]),("il16",["e15-03.ic11","e15-01.ic7"])],
   "sprites_hi":[],
   "tilemap":[("il32w",["e15-10.ic47","e15-08.ic45"]),("il32w",["e15-09.ic46","e15-07.ic44"])],
   "tilemap_hi":[],
   "ensoniq":[("raw","e15-05.ic38"),("raw","e15-06.ic41")]}),
(dict(set="quizhuhu", name="Quiz de Hyuuhyuu", year="1994", map=1,
       rot="horizontal", cfg1=0xC3, cfg2=0x04, vis=3, ext=1, id=31,
       btn="Button 1,Button 2,-,-,-,-,Start,Coin,Service,Pause",
       note=P1N + "Moriguchi Hiroko no Quiz de Hyuuhyuu. Horizontal (MAME ROT0). " + E16 + MIR),
  {"maincpu":[("il32",["e08-16.20","e08-15.19","e08-14.18","e08-13.17"])],
   "audiocpu":[("il16",["e08-18.32","e08-17.33"]),("il16",["e08-18.32","e08-17.33"])],
   "sprites":[("il16",["e08-06.12","e08-04.8"]),("il16",["e08-05.11","e08-03.7"])],
   "sprites_hi":[("raw","e08-02.4"),("raw","e08-01.3")],
   "tilemap":[("il32w",["e08-12.47","e08-11.45"])],
   "tilemap_hi":[("raw","e08-10.43")],
   "ensoniq":[("pad",0x200000,"ensoniq bank 0 is empty in MAME"),
              ("raw","e08-07.38"),("raw","e08-08.39"),("raw","e08-09.41")]}),

 (dict(set="puchicar", name="Puchi Carat", year="1997", map=1,
       rot="horizontal", cfg1=0x43, cfg2=0x05, vis=3, ext=1, id=33,
       btn="Button 1,Button 2,-,-,-,-,Start,Coin,Service,Pause",
       note=P1N + "Horizontal (MAME ROT0). " + E16),
  {"maincpu":[("il32",["e46-16.ic20","e46-15.ic19","e46-14.ic18","e46-18.ic17"])],
   "audiocpu":[("il16",["e46-21.ic32","e46-22.ic33"])],
   "sprites":[("il16",["e46-06.ic12","e46-04.ic8"]),("il16",["e46-05.ic11","e46-03.ic7"])],
   "sprites_hi":[("raw","e46-02.ic4"),("raw","e46-01.ic3")],
   "tilemap":[("il32w",["e46-12.ic47","e46-11.ic45"])],
   "tilemap_hi":[("raw","e46-10.ic43")],
   "ensoniq":[("pad",0x200000,"ensoniq bank 0 is empty in MAME"),
              ("raw","e46-07.ic38"),("raw","e46-08.ic39"),("raw","e46-09.ic40")]}),

 (dict(set="kaiserkn", name="Kaiser Knuckle", year="1994", map=1,
       rot="horizontal", cfg1=0x80, cfg2=0x05, vis=0, ext=0, id=34,
       btn="Light Punch,Medium Punch,Heavy Punch,Light Kick,Medium Kick,Heavy Kick,Start,Coin,Service,Pause",
       note=P1N + "Global Champion outside Japan. THE LARGEST SET IN THE LIBRARY BAR ONE at 36 MB: 13 MB of sprites, 6.5 MB of sprites_hi and 3 MB of tilemap_hi, which is what sized profile 1. " + E16 + "Its bank 1 is empty too, and the third sample ROM sits at bank 7."),
  {"maincpu":[("il32",["d84-25.20","d84-24.19","d84-23.18","d84-29.17"])],
   "audiocpu":[("il16",["d84-26.32","d84-27.33"])],
   "sprites":[("il16",["d84-03.rom","d84-04.rom"]),("il16",["d84-06.rom","d84-07.rom"]),
              ("il16",["d84-09.rom","d84-10.rom"]),("il16",["d84-19.rom","d84-20.rom"])],
   "sprites_hi":[("raw","d84-05.rom"),("raw","d84-08.rom"),("raw","d84-11.rom"),("raw","d84-21.rom")],
   "tilemap":[("il32w",["d84-12.rom","d84-13.rom"]),("il32w",["d84-16.rom","d84-17.rom"])],
   "tilemap_hi":[("raw","d84-14.rom"),("raw","d84-18.rom")],
   "ensoniq":[("pad",0x200000,"ensoniq bank 0 is empty in MAME"),
              ("raw","d84-01.rom"),("raw","d84-02.rom"),
              ("pad",0x100000,"1 MB hole before the last sample ROM (MAME 0xC00000-0xDFFFFF)"),
              ("raw","d84-15.rom")]}),

 (dict(set="dankuga", name="Dan-Ku-Ga", year="1994", map=1,
       rot="horizontal", cfg1=0xC0, cfg2=0x05, vis=0, ext=0, id=35,
       btn="Light Punch,Medium Punch,Heavy Punch,Light Kick,Medium Kick,Heavy Kick,Start,Coin,Service,Pause",
       note=P1N + "A PROTOTYPE, and Kaiser Knuckle's graphics and samples entirely -- only the program differs. See that MRA for the layout notes."),
  {"maincpu":[("il32",["dkg_mpr3.20","dkg_mpr2.19","dkg_mpr1.18","dkg_mpr0.17"])],
   "audiocpu":[("il16",["d84-26.32","d84-27.33"])],
   "sprites":[("il16",["d84-03.rom","d84-04.rom"]),("il16",["d84-06.rom","d84-07.rom"]),
              ("il16",["d84-09.rom","d84-10.rom"]),("il16",["d84-19.rom","d84-20.rom"])],
   "sprites_hi":[("raw","d84-05.rom"),("raw","d84-08.rom"),("raw","d84-11.rom"),("raw","d84-21.rom")],
   "tilemap":[("il32w",["d84-12.rom","d84-13.rom"]),("il32w",["d84-16.rom","d84-17.rom"])],
   "tilemap_hi":[("raw","d84-14.rom"),("raw","d84-18.rom")],
   "ensoniq":[("pad",0x200000,"ensoniq bank 0 is empty in MAME"),
              ("raw","d84-01.rom"),("raw","d84-02.rom"),
              ("pad",0x100000,"1 MB hole before the last sample ROM (MAME 0xC00000-0xDFFFFF)"),
              ("raw","d84-15.rom")]}),
]

# explicit filenames: deriving one from the display name silently overwrote
# the existing Darius Gaiden.mra, whose Extra Version shares its prefix
FILE = {"spcinv95": "Space Invaders '95", "cleopatr": "Cleopatra Fortune",
        "twinqix": "Twin Qix", "recalh": "Recalhorn", "qtheater": "Quiz Theater",
        "popnpop": "Pop 'n Pop", "gekiridn": "Gekirindan",
        "dariusgx": "Darius Gaiden Extra Version",
        "pbobble3": "Puzzle Bobble 3", "pbobble4": "Puzzle Bobble 4",
        "arabianm": "Arabian Magic", "ridingf": "Riding Fight",
        "ringrage": "Ring Rage", "landmakr": "Land Maker",
        "trstar": "Top Ranking Stars", "cupfinal": "Taito Cup Finals",
        "intcup94": "International Cup 94", "scfinals": "Super Cup Finals",
        "pwrgoal": "Taito Power Goal", "commandw": "Command War",
        "lightbr": "Light Bringer", "tcobra2": "Twin Cobra II",
        "quizhuhu": "Quiz de Hyuuhyuu", "puchicar": "Puchi Carat",
        "kaiserkn": "Kaiser Knuckle", "dankuga": "Dan-Ku-Ga"}

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
