-- Start a REAL game headless (coin, start), optionally hold the zone byte at
-- ZG_VAL from just before start, and snapshot at offsets after start.
_G.ZG = _G.ZG or {}
local val   = tonumber(os.getenv("ZG_VAL") or "0")
local addrs = {}; for a in string.gmatch(os.getenv("ZG_ADDRS") or "402313", "[^,]+") do addrs[#addrs+1] = tonumber(a, 16) end
local shots = {}; for s in string.gmatch(os.getenv("ZG_SHOTS") or "900", "[^,]+") do shots[tonumber(s)] = true end
local n, started, sp = 0, nil, nil
local function field(port, name) return manager.machine.ioport.ports[port].fields[name] end
_G.ZG.f = emu.add_machine_frame_notifier(function()
    n = n + 1; sp = sp or manager.machine.devices[":maincpu"].spaces["program"]
    if n == 400 then field(":EEPROMIN", "Coin 1"):set_value(1); print("COIN down") end
    if n == 410 then field(":EEPROMIN", "Coin 1"):set_value(0) end
    if n == 600 then field(":IN.0", "1 Player Start"):set_value(1); print("START down") end
    if n == 700 then field(":IN.0", "1 Player Start"):set_value(0); started = n end
    if val ~= 0 and n >= 590 then for _,a in ipairs(addrs) do sp:write_u8(a, val) end end
    if n % 200 == 0 then print(string.format("f%d zone=%d credit-ish=%d", n, sp:read_u8(0x402313), sp:read_u8(0x402311))) end
    if started and shots[n - started] then
        print(string.format("SHOT +%d  zone=%d shadow=%d  0x402311=%d", n - started, sp:read_u8(0x402313), sp:read_u8(0x4038C1), sp:read_u8(0x402311)))
        manager.machine.video:snapshot()
    end
end)
