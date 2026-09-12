-- Where in the raster does the game write the video control registers?
--
-- The core renders per line and applies 0x660000-0x66001F live (rf_main.sv
-- c0/c1, no latch), so a write that lands under the beam tears the picture at
-- that line. Elevator Action Returns tears while it scrolls vertically. Two
-- explanations fit, and they need opposite fixes:
--
--   the CPU is late   this core does 79 % of a real 68020's work, so frame
--                     work that belongs in vblank spills into the visible
--                     raster. Then MAME writes these registers in vblank and
--                     the core writes them at a visible line -- speeding the
--                     CPU up is the fix.
--   the F3 latches    real hardware writes them mid-frame too and does not
--                     tear, which would mean the registers are latched
--                     somewhere the core applies them live. No CPU speed
--                     fixes that; the core has to latch them.
--
-- Reports, per frame, min/max/count of the raster line at each write -- the
-- same three numbers as the core's self-test row VCTRL MIN:MAX:N, so the two
-- are read side by side. Line -1 means the write was inside vblank.
--
-- MAME 0.288 binds neither screen:vpos() nor screen.visible_area, so the line
-- comes from the vblank timer: t_in_frame = period - time_until_vblank_start,
-- and MAME's frame boundary IS vblank start, so vblank is t < its duration.
--
-- SDL_VIDEODRIVER=dummy mame elvactr -rompath /storage02/roms/mame \
--   -video none -sound none -nothrottle -norotate \
--   -autoboot_script tools/mame/vctrltap.lua -seconds_to_run 60
--
-- env: VT_OUT  csv path (default /tmp/vctrl.csv)
--      VT_SKIP frames to ignore first (default 200, boot/POST)
--      VT_LO   lo address (default 0x660000)   VT_HI (default 0x66001F)

_G.VT = _G.VT or {}

local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]
local scr
for _, s in pairs(manager.machine.screens) do scr = s break end

local OUT  = os.getenv("VT_OUT") or "/tmp/vctrl.csv"
local SKIP = tonumber(os.getenv("VT_SKIP") or "200")
local LO   = tonumber(os.getenv("VT_LO") or "0x660000")
local HI   = tonumber(os.getenv("VT_HI") or "0x66001F")
local DUMP_EVERY = tonumber(os.getenv("VT_EVERY") or "500")

local H      = scr.height                 -- visible lines
local PERIOD = 1.0 / scr.refresh
local VBL    = nil                        -- vblank duration, measured once
local LT     = nil                        -- seconds per line
local VBL_LINES = nil                     -- lines of vblank at the top

local dump          -- defined below, called from the frame notifier
local n = 0
local lmin, lmax, lcnt, lvis = 9999, -9999, 0, 0
local rows = {}
local off_vis, pc_vis = {}, {}
local lastval = {}          -- offset -> most recent value this frame
local frames_with_vis = 0

-- Line counted from vblank START, the way the frame is actually ordered:
-- 0 .. VBL_LINES-1 are vblank, VBL_LINES .. VBL_LINES+H-1 are the visible
-- raster. Reporting it this way shows the MARGIN -- how much of vblank the
-- game's register update still had left -- which is the number that decides
-- whether a slower CPU spills into the picture.
local function line_now()
    if VBL == nil then return -1 end
    local dt = scr:time_until_vblank_start():as_double()
    local t  = PERIOD - dt                       -- seconds since vblank start
    return math.floor(t / LT)
end

_G.VT.tap = sp:install_write_tap(LO, HI, "vctrl", function(offset, data, mask)
    if n < SKIP then return end
    local l = line_now()
    if l < lmin then lmin = l end
    if l > lmax then lmax = l end
    lcnt = lcnt + 1
    lastval[offset % 0x20] = data
    if l >= VBL_LINES then
        lvis = lvis + 1
        local o = string.format("%06X", LO + (offset % 0x20))
        off_vis[o] = (off_vis[o] or 0) + 1
        local pc = string.format("%06X", cpu.state["PC"].value)
        pc_vis[pc] = (pc_vis[pc] or 0) + 1
    end
end)

_G.VT.f = emu.add_machine_frame_notifier(function()
    if VBL == nil then
        -- the notifier fires at vblank start, so this IS the vblank duration
        VBL = scr:time_until_vblank_end():as_double()
        LT  = (PERIOD - VBL) / H
        VBL_LINES = math.floor(VBL / LT + 0.5)
        print(string.format("SCREEN %dx%d  %.4f Hz  vblank %.4f ms = %.1f lines",
              scr.width, H, scr.refresh, VBL * 1000.0, VBL / ((PERIOD - VBL) / H)))
    end
    if n >= SKIP and lcnt > 0 then
        local vals = {}
        for o = 0, 0x1E, 2 do vals[#vals+1] = string.format("%04X", lastval[o] or 0) end
        rows[#rows + 1] = string.format("%d,%d,%d,%d,%d,%s",
                                        n, lmin, lmax, lcnt, lvis, table.concat(vals, ":"))
        if lvis > 0 then frames_with_vis = frames_with_vis + 1 end
    end
    lmin, lmax, lcnt, lvis = 9999, -9999, 0, 0
    n = n + 1
    if n > SKIP and (n % DUMP_EVERY) == 0 then dump() end
end)

-- add_machine_stop_notifier does not fire in MAME 0.288, so the dump is
-- frame-triggered the way ramdump2.lua/zonewrite.lua do it. It rewrites
-- every DUMP_EVERY frames, so a run cut short still leaves a usable file.
function dump()
    local f = assert(io.open(OUT, "w"))
    f:write("frame,lmin,lmax,count,in_visible,regs\n")
    f:write(table.concat(rows, "\n")); f:write("\n"); f:close()
    print(string.format("VCTRL %d frames with writes, %d of them under the beam -> %s",
          #rows, frames_with_vis, OUT))
    local any = false
    for o, c in pairs(off_vis) do print(string.format("UNDER BEAM reg %s x%d", o, c)); any = true end
    for p, c in pairs(pc_vis) do print(string.format("UNDER BEAM from PC %s x%d", p, c)) end
    if not any then print("UNDER BEAM none -- every write was inside vblank") end
end
