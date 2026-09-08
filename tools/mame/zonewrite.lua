_G.ZW = _G.ZW or {}
local n = 0; local cpu = manager.machine.devices[":maincpu"]; local sp = cpu.spaces["program"]
local function field(port, name) return manager.machine.ioport.ports[port].fields[name] end
local seen = {}
_G.ZW.tap = sp:install_write_tap(0x402310, 0x402313, "zonew", function(offset, data, mask)
    local pc = cpu.state["PC"].value; local k = string.format("%06X", pc)
    seen[k] = (seen[k] or 0) + 1
    if seen[k] <= 4 then print(string.format("WRITE zone @f%d PC=%06X data=%08X mask=%08X", n, pc, data, mask)) end
end)
_G.ZW.f = emu.add_machine_frame_notifier(function()
    n = n + 1
    if n == 400 then field(":EEPROMIN","Coin 1"):set_value(1) end
    if n == 410 then field(":EEPROMIN","Coin 1"):set_value(0) end
    if n == 600 then field(":IN.0","1 Player Start"):set_value(1) end
    if n == 700 then field(":IN.0","1 Player Start"):set_value(0) end
    if n == 1000 then
        local f = assert(io.open(os.getenv("ZW_OUT") or "/tmp/ram_z1game.bin","wb")); local t = {}
        for a = 0x400000, 0x43FFFF, 4 do t[#t+1] = string.pack(">I4", sp:read_u32(a)) end
        f:write(table.concat(t)); f:close(); print("RAMDUMP zone1 gameplay f1000")
    end
end)
