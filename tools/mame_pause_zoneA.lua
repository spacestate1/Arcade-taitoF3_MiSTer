-- Boot Darius Gaiden, coin up, press 1P start, and PAUSE MAME at frame 864 --
-- the Zone A moment that matches the board's paused screen (two big towers).
--
--   mame dariusg -rompath /storage02/roms/mame -autoboot_script tools/mame_pause_zoneA.lua
--
-- Then in MAME: P unpauses, Shift+P steps one frame. Set PAUSE_AT in the
-- environment to stop somewhere else (e.g. PAUSE_AT=972).
_G.K = _G.K or {}
local coinf, startf = 240, 600
local pause_at = tonumber(os.getenv("PAUSE_AT") or "864")
local p = manager.machine.ioport.ports
local coin = p[":EEPROMIN"].fields["Coin 1"]
local st   = p[":IN.0"].fields["1 Player Start"]
local n = 0
table.insert(_G.K, emu.add_machine_frame_notifier(function()
  n = n + 1
  if n >= coinf  and n < coinf  + 10 then coin:set_value(1) elseif n == coinf  + 10 then coin:set_value(0) end
  if n >= startf and n < startf + 10 then st:set_value(1)   elseif n == startf + 10 then st:set_value(0)   end
  if n == pause_at then emu.pause(); print("paused at frame " .. n) end
end))
