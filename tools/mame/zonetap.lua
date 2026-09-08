-- Log every READ of the zone byte: frame, PC, value. Says WHEN the game
-- consumes it and from WHERE, which is what an injector has to know.
_G.ZT = _G.ZT or {}
local n = 0
local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]
local seen = {}
_G.ZT.tap = sp:install_read_tap(0x402310, 0x402313, "zonetap", function(offset, data, mask)
    local pc = cpu.state["PC"].value
    local key = string.format("%06X", pc)
    seen[key] = (seen[key] or 0) + 1
    if seen[key] <= 3 then print(string.format("READ zone @frame %d  PC=%06X  data=%08X mask=%08X", n, pc, data, mask)) end
end)
_G.ZT.f = emu.add_machine_frame_notifier(function() n = n + 1
    if n == 3000 then for k,v in pairs(seen) do print(string.format("TOTAL PC=%s reads=%d", k, v)) end end end)
