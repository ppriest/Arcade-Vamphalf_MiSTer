local n = tonumber(os.getenv("CORE_SNAP_FRAME") or "2700")
local out = os.getenv("CORE_SNAP_OUT")
local f = 0
core_snap_sub = emu.add_machine_frame_notifier(function()
  f = f + 1
  if f == n then manager.machine.video:snapshot() end
  if f == n + 2 then manager.machine:exit() end
end)
