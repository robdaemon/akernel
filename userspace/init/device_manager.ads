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
   --  Launch the display stack (Bureau + terminal) from the Sys
   --  filesystem; call after the FS chain is online and
   --  Akernel_User.Files is bound.
   procedure Start_Display;
   function Block_Service return Akernel_User.Syscalls.U64;
   --  Net_Service returns init's Send side of the service endpoint
   --  of the spawned virtio class-1 (network) driver, 0 when no
   --  network device was found; init grants it to System/Netserv
   --  via the "netdev" manifest token.
   function Net_Service return Akernel_User.Syscalls.U64;
   --  The elevation service (milestone 45): init creates the
   --  endpoint and stores it here (Send side for the
   --  "elevated_svc" manifest token); Start_Elevated stages and
   --  spawns System/Elevated from the Sys volume with the
   --  Receive side and the admin bootinfo cap. Tolerates a
   --  missing image (logs and returns; Elevate then fails
   --  cleanly on the unanswered Call).
   Elevated_EP : Akernel_User.Syscalls.U64 := 0;
   --  Netserv client endpoint (m71c): init hands the owner cap
   --  here so Spawn_Program can grant the Send side to Sys:
   --  programs at uniform handle 5 (terminals re-grant it to
   --  their shells at handle 6).
   Net_Client_EP : Akernel_User.Syscalls.U64 := 0;
   --  Library manager endpoint (milestone 65): Send side granted to
   --  every spawned program so Open_Library can reach the manager.
   Libman_EP : Akernel_User.Syscalls.U64 := 0;
   procedure Start_Elevated;
end Device_Manager;
