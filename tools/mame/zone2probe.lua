-- Start a real game at zone 2 and dump work RAM at intervals, so a monotonic
-- stage-progress counter can be found by diffing the dumps offline.
_G.ZP = _G.ZP or {}
local val  = tonumber(os.getenv("ZP_VAL") or "2")
local out  = os.getenv("ZP_OUT") or "/tmp/z2"
local lives= tonumber(os.getenv("ZP_LIVES") or "0")   -- byte to hold, 0 = off
local every= tonumber(os.getenv("ZP_EVERY") or "300")
local last = tonumber(os.getenv("ZP_LAST") or "6000")
local n, started, hits = 0, nil, 0
local cpu = manager.machine.devices[":maincpu"]; local sp = cpu.spaces["program"]
local function field(p,f) return manager.machine.ioport.ports[p].fields[f] end
_G.ZP.tap = sp:install_write_tap(0x402310, 0x402313, "zp", function(offset, data, mask)
    if val ~= 0 and mask == 0x0000FFFF and (data & 0xFFFF) == 1 then
        hits = hits + 1
        return (data & 0xFFFF0000) | val
    end
end)
local function dump(tag)
    local f = io.open(string.format("%s/ram_%s.bin", out, tag), "wb")
    for a = 0x400000, 0x43FFFF do f:write(string.char(sp:read_u8(a))) end
    f:close()
end
_G.ZP.f = emu.add_machine_frame_notifier(function()
    n = n + 1
    if n == 400 then field(":EEPROMIN","Coin 1"):set_value(1) end
    if n == 410 then field(":EEPROMIN","Coin 1"):set_value(0) end
    if n == 600 then field(":IN.0","1 Player Start"):set_value(1) end
    if n == 700 then field(":IN.0","1 Player Start"):set_value(0); started = n end
    if lives ~= 0 and started then sp:write_u8(lives, 9) end
    if started then
        local d = n - started
        if d > 0 and d % every == 0 and d <= last then
            dump(string.format("%05d", d))
            print(string.format("DUMP +%d zone=%d", d, sp:read_u8(0x402313)))
            manager.machine.video:snapshot()
        end
    end
end)
