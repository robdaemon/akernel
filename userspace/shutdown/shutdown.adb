with Aegir_User.CLI;
with Aegir_User.Console;
with Aegir_User.Files;
with Aegir_User.Syscalls;
--  Shutdown: flush every mounted volume, then power the machine
--  off through SBI SRST (milestone 50; the Amiga has no analog —
--  AmigaOS never learned to shut down). Runs ONLY under Elevate:
--  the reset syscall needs the admin cap, which lands at handle 5
--  as a Manage-only mint; the fs cap at handle 2 drives the sync
--  fan-out (fileserver -> fat32 -> partmgr -> virtio-blk ->
--  VIRTIO_BLK_T_FLUSH). There are no signals to deliver and
--  nothing to deliver them to: the filesystem is the only
--  cross-process durable state, so sync + power cut IS the clean
--  shutdown. On success System_Reset never returns.

procedure Shutdown is
   use Aegir_User.Syscalls;
   use type U64;

   Console_EP : constant U64 := 1;  --  Elevated grant order
   FS_EP      : constant U64 := 2;
   Admin_Cap  : constant U64 := 5;

   St : U64;
begin
   Aegir_User.Console.Set_Endpoint (Console_EP);
   Aegir_User.Files.Bind (FS_EP);
   St := Aegir_User.Files.Sync;
   if St /= Aegir_User.Files.Status_Ok then
      Aegir_User.CLI.Fail_With
        ("Shutdown: filesystem sync failed", Aegir_User.CLI.RC_Fail);
   end if;
   Aegir_User.Console.Put_Line ("shutdown: filesystems synced");
   St := System_Reset (Admin_Cap, Reset_Shutdown);
   --  Reached only when the reset was rejected:
   Aegir_User.CLI.Fail_With
     ("Shutdown: reset rejected", Aegir_User.CLI.RC_Fail);
end Shutdown;
