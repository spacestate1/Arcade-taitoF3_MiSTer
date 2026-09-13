# Set the core's saved OSD status byte 0 on the board, e.g. 0x38 = Self Test
# Off + UART Debug = Sound Ring; 0x08 = Self Test Off + UART = Self Test page.
import sys
sys.path.insert(0, 'tools')
import rf_deploy as d
val = int(sys.argv[1], 16)
# optional second byte: OSD status bits 8-15 (Scandoubler Fx, Refresh Rate,
# Stereo Mix, Flip Screen, Pause When OSD Open) -- e.g. setcfg.py 08 40 sets
# Flip Screen on with the page in self-test mode
val1 = int(sys.argv[2], 16) if len(sys.argv) > 2 else None
# optional third byte: OSD status bits 16-23 (Audio Boost, CPU Speed, Flip
# Analog Out) -- e.g. setcfg.py 80 00 20 is Rotate: None with Flip Analog Out
# ON. Note bits 2 and 3 (Service Mode, Self Test) canNOT be set this way: the
# core ARMS them (st_inherit / sv_inherit in Rayforce.sv), so a value handed
# over by the config file at the end of the ROM download is ignored on
# purpose -- that is release rule 3, "games must boot to the game".
val2 = int(sys.argv[3], 16) if len(sys.argv) > 3 else None
c = d.connect()
sftp = c.open_sftp()
path = "/media/fat/config/Rayforce.CFG"
try:
    cur = bytearray(sftp.open(path, "rb").read())
except IOError:
    cur = bytearray(16)
if len(cur) < 1: cur = bytearray(16)
cur[0] = val & 0xff
if val1 is not None:
    cur[1] = val1 & 0xff
if val2 is not None:
    cur[2] = val2 & 0xff
sftp.open(path, "wb").write(bytes(cur))
sftp.close(); c.close()
print(f"Rayforce.CFG[0] = {val:02x}"
      + (f", [1] = {val1:02x}" if val1 is not None else "")
      + (f", [2] = {val2:02x}" if val2 is not None else ""))
