with Interfaces;

package Board.RTC is
   --  Goldfish RTC (qemu virt platform device at 0x101000): wall
   --  clock as nanoseconds since the Unix epoch, read-only.
   --  MMIO base defaults to the board constant (qemu virt always
   --  has the device); the kernel overrides it from DTB discovery
   --  ("google,goldfish-rtc") before userspace starts. Read returns
   --  0 when the device never ticks — the absence signal.
   procedure Set_Base (Physical_Base : Interfaces.Unsigned_64);

   function Present return Boolean;

   --  Nanoseconds since 1970-01-01T00:00:00Z, or 0 when no RTC.
   --  Register pair read high-low-high against a mid-read tick.
   function Read_Nanoseconds return Interfaces.Unsigned_64;
end Board.RTC;
