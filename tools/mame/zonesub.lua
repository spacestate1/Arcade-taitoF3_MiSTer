-- Substitute the zone word AT THE WRITE: when the new-game init (PC 004810)
-- stores 1 into 0x402312/13, hand the bus ZS_VAL instead, and also write it
-- back immediately so a tap that cannot modify data still wins the race.
_G.ZS = _G.ZS or {}
local val = tonumber(os.getenv("ZS_VAL") or "2")
local n, started, hits = 0, nil, 0
local cpu = manager.machine.devices[":maincpu"]; local sp = cpu.spaces["program"]
local function field(port, name) return manager.machine.ioport.ports[port].fields[name] end
_G.ZS.tap = sp:install_write_tap(0x402310, 0x402313, "zonesub", function(offset, data, mask)
    if val ~= 0 and mask == 0x0000FFFF and (data & 0xFFFF) == 1 then
        hits = hits + 1
        if hits <= 3 then print(string.format("SUBST @f%d PC=%06X %08X -> %08X", n, cpu.state["PC"].value, data, (data & 0xFFFF0000) | val)) end
        return (data & 0xFFFF0000) | val
    end
end)
_G.ZS.f = emu.add_machine_frame_notifier(function()
    n = n + 1
    if n == 400 then field(":EEPROMIN","Coin 1"):set_value(1) end
    if n == 410 then field(":EEPROMIN","Coin 1"):set_value(0) end
    if n == 600 then field(":IN.0","1 Player Start"):set_value(1) end
    if n == 700 then field(":IN.0","1 Player Start"):set_value(0); started = n end
    if started and (n - started == 600 or n - started == 1500) then
        print(string.format("SHOT +%d zone=%d 402317=%d 402319=%d", n - started, sp:read_u8(0x402313), sp:read_u8(0x402317), sp:read_u8(0x402319)))
        manager.machine.video:snapshot()
    end
end)
