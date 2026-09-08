_G.WD = _G.WD or {}
local base = os.getenv("WD_OUT") or "/tmp/ram"
local want = {}; for s in string.gmatch(os.getenv("WD_AT") or "30", "[^,]+") do want[tonumber(s)] = true end
local function dump(tag)
    local sp = manager.machine.devices[":maincpu"].spaces["program"]
    local f = assert(io.open(base .. "_" .. tag .. ".bin", "wb")); local t = {}
    for a = 0x400000, 0x43FFFF, 4 do t[#t+1] = string.pack(">I4", sp:read_u32(a)) end
    f:write(table.concat(t)); f:close(); print("RAMDUMP " .. tag)
end
pcall(function() _G.WD.pl = emu.add_machine_post_load_notifier(function() dump("postload") end) end)
local n = 0
_G.WD.f = emu.add_machine_frame_notifier(function() n = n + 1; if want[n] then dump("f" .. n) end end)
