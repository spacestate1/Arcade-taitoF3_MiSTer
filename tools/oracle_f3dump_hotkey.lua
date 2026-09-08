-- Taito F3 video-state oracle.
--
-- Dumps every video RAM the TC0630FDP/TC0650FDA/TC0660FCM chipset reads, plus
-- the playfield control registers, plus MAME's own rendered frame as a PNG --
-- all at the same emulated instant. That set is a complete input/output pair
-- for the renderer: given these bytes, the chips produce that picture. It is
-- what the Python model is checked against, and then what the RTL is checked
-- against, without either of them being allowed to define what "correct"
-- means.
--
-- Why the snapshot is forced inside the same callback: MAME renders lazily,
-- so calling video:snapshot() here re-renders from exactly the VRAM being
-- written out. Dumping in one callback and snapshotting in another skews the
-- two by a frame, which shows up later as a renderer bug that is not there.
--
-- Handles live in _G because notifiers are garbage collected otherwise
-- (raiden2 #50, learned the hard way).
--
-- usage:
--   F3DUMP_FRAMES=60,300,900 F3DUMP_DIR=dump \
--   mame rayforce -rompath . -video none -sound none -nothrottle -norotate \
--        -autoboot_script tools/oracle_f3dump.lua -seconds_to_run 40

_G.F3D_KEEP = _G.F3D_KEEP or {}

local dir    = os.getenv("F3DUMP_DIR")    or "dump"
local frames = os.getenv("F3DUMP_FRAMES") or "600"

local want = {}
for s in string.gmatch(frames, "[^,]+") do want[tonumber(s)] = true end

-- 0x660000-0x66001f is write-only in the driver, so the only way to see the
-- playfield/pivot scroll registers is to watch them being written.
local ctrl = {}
for i = 0, 15 do ctrl[i] = 0 end

local sp = manager.machine.devices[":maincpu"].spaces["program"]
table.insert(_G.F3D_KEEP, sp:install_write_tap(0x660000, 0x66001f, "f3ctrl",
    function(offset, data, mask)
        -- 32-bit space: one access can carry two 16-bit registers.
        local w = (offset - 0x660000) // 2
        if (mask & 0xffff0000) ~= 0 then ctrl[w]     = (data >> 16) & 0xffff end
        if (mask & 0x0000ffff) ~= 0 then ctrl[w + 1] = data & 0xffff end
    end))

local function dump_share(tag, path)
    local sh = manager.machine.memory.shares[tag]
    if not sh then print("MISSING SHARE " .. tag) return end
    local f = assert(io.open(path, "wb"))
    -- Byte order as the 68020 sees it: these shares are big-endian, so a
    -- straight byte dump is already the image the FPGA BRAMs hold.
    local chunk = {}
    for i = 0, sh.size - 1 do
        chunk[#chunk + 1] = string.char(sh:read_u8(i))
        if #chunk == 4096 then f:write(table.concat(chunk)); chunk = {} end
    end
    if #chunk > 0 then f:write(table.concat(chunk)) end
    f:close()
    print(string.format("  %-12s %6d bytes -> %s", tag, sh.size, path))
end

local n = 0
local armed = 0
-- A state load (F7) resets the machine and DROPS this notifier -- measured:
-- -state on the command line and manager.machine:load() both dump nothing.
-- Registering again on reset lets you jump straight to a saved state and
-- still capture. _G.F3D_ON guards against stacking duplicate notifiers.
local frame_cb = function()
    n = n + 1
    -- HOTKEY VARIANT: -state and machine:load() both silently kill this
    -- notifier, so the state-replay route does not work. Instead the user
    -- plays to the scene and presses F8; the next three frames are dumped,
    -- which is exactly the run the pipe bench needs (frame + two of sprite
    -- history).
    if armed == 0 then
        local ok, code = pcall(function()
            return manager.machine.input:code_from_token("KEYCODE_F8")
        end)
        if ok and code and manager.machine.input:code_pressed(code) then
            armed = 3
            print("=== F3 DUMP ARMED, capturing 3 frames ===")
        end
        return
    end
    armed = armed - 1

    local pre = string.format("%s/f3_%05d_", dir, n)
    print(string.format("=== F3 DUMP frame %d ===", n))
    dump_share(":spriteram",  pre .. "spriteram.bin")
    dump_share(":pf_ram",     pre .. "pf_ram.bin")
    dump_share(":textram",    pre .. "textram.bin")
    dump_share(":charram",    pre .. "charram.bin")
    dump_share(":line_ram",   pre .. "line_ram.bin")
    dump_share(":pivot_ram",  pre .. "pivot_ram.bin")
    dump_share(":paletteram", pre .. "paletteram.bin")

    local f = assert(io.open(pre .. "ctrl.txt", "w"))
    for i = 0, 15 do f:write(string.format("%02d %04x\n", i, ctrl[i])) end
    f:close()
    print(string.format("  ctrl         16 words -> %sctrl.txt", pre))

    -- Force a render from exactly the state just written out, and take the
    -- pixels straight out of the video manager instead of letting MAME name
    -- a PNG: snapshot() auto-increments its filename, which silently
    -- decouples the picture from the .bin set it belongs to.
    --
    -- Run MAME with -norotate for this. Ray Force is a ROT90 cabinet, so the
    -- rotated snapshot is 224x320; the renderer works in raster order and
    -- has to be compared against the unrotated 320x224 frame.
    local w, h = manager.machine.video:snapshot_size()
    local px = manager.machine.video:snapshot_pixels()
    local sf = assert(io.open(pre .. "frame.argb", "wb"))
    sf:write(px)
    sf:close()
    local mf = assert(io.open(pre .. "frame.txt", "w"))
    mf:write(string.format("%d %d\n", w, h))
    mf:close()
    print(string.format("  frame        %dx%d -> %sframe.argb", w, h, pre))
    io.stdout:flush()
end
local function register()
    if _G.F3D_ON then return end
    _G.F3D_ON = true
    table.insert(_G.F3D_KEEP, emu.add_machine_frame_notifier(frame_cb))
end
register()
table.insert(_G.F3D_KEEP, emu.add_machine_reset_notifier(function()
    _G.F3D_ON = false
    register()
end))

-- One-time dump of the gfx regions, so the Python model and the Verilator
-- bench work from exactly the bytes MAME assembled out of the zip (the
-- interleaves in ROM_LOAD32_WORD / ROM_LOAD16_BYTE are easy to get subtly
-- wrong, and a wrong interleave looks like a broken tile decoder).
local function dump_region(tag, path)
    local rg = manager.machine.memory.regions[tag]
    if not rg then print("MISSING REGION " .. tag) return end
    local f = assert(io.open(path, "wb"))
    local chunk = {}
    for i = 0, rg.size - 1 do
        chunk[#chunk + 1] = string.char(rg:read_u8(i))
        if #chunk == 65536 then f:write(table.concat(chunk)); chunk = {} end
    end
    if #chunk > 0 then f:write(table.concat(chunk)) end
    f:close()
    print(string.format("  %-14s %8d bytes -> %s", tag, rg.size, path))
end

if os.getenv("F3DUMP_REGIONS") then
    local done = false
    table.insert(_G.F3D_KEEP, emu.add_machine_frame_notifier(function()
        if done then return end
        done = true
        print("=== F3 REGION DUMP ===")
        dump_region(":tilemap",    dir .. "/rgn_tilemap.bin")
        dump_region(":tilemap_hi", dir .. "/rgn_tilemap_hi.bin")
        dump_region(":sprites",    dir .. "/rgn_sprites.bin")
        dump_region(":sprites_hi", dir .. "/rgn_sprites_hi.bin")
        io.stdout:flush()
    end))
end
