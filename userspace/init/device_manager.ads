with Akernel_User.Syscalls;

--  Device manager (lives in init for now; packaged separately so it
--  can move to its own program later). Reads the driver database
--  (System/Drivers: "driver <compatible> <path> <probe> <class>"),
--  walks the DTB (the "dtb" boot file), probes matching nodes, and
--  spawns the driver image with a per-instance grant set:
--    handle 1 = console endpoint (Send, badged with the driver id)
--    handle 2 = device MMIO cap (io_map of the node's reg)
--    handle 3 = IRQ cap (irq_create of the node's interrupts cell,
--               only when the node carries interrupts)
--    handle 4 = block service endpoint (Receive; a fresh endpoint
--               per instance, always granted — drivers without a
--               service simply never receive on it)
--  Probe "virtio": map the registers and compare the device id at
--  MMIO offset 0x08 against the line's class. Probe "none": spawn
--  on compatible match alone.
--
--  Block_Service returns init's Send side of the service endpoint
--  of the spawned virtio class-2 (block) driver, 0 when no block
--  device was found; init hands it to the file server (Op_Add_Block)
--  to mount a block-backed volume.

package Device_Manager is
   procedure Run (Console_EP : Akernel_User.Syscalls.U64);
   function Block_Service return Akernel_User.Syscalls.U64;
end Device_Manager;
