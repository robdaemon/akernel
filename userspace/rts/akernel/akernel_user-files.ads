with System;
with Akernel_User.Syscalls;

--  9P-ish file protocol over endpoint RPC (docs/IPC.md): the file
--  server (System/Fileserver) holds the boot-file caps; clients hold
--  only an endpoint Send cap. Protocol labels on the message:
--
--    Op_Set_Name = 0   init -> server: (handle, length, name[32])
--    Op_Stat     = 1   words = name[48] -> (status, size)
--    Op_Open     = 2   words = name[48] -> (status, size)
--    Op_Read     = 3   (offset, length, name[32]) + buffer memory
--                      cap in cap slot 0 -> (status, count); bytes
--                      appear at offset 0 of the client's buffer
--
--    Op_Mount    = 4   init -> server: (devlen, labellen, ci,
--                      device ++ label chars[24]) from the manifest's
--                      volume directive
--
--  Statuses: 0 ok, 1 not found, 2 server not ready (name table not
--  yet pushed by init), 3 bad arguments, 4 out of range.
--
--  Wire names are volume-qualified Amiga-style: "RD0:System/Init"
--  or via the volume label "Initrd:System/Init". Volume prefixes
--  always compare case-insensitively; path comparison follows the
--  mounted filesystem's case flag. Unqualified names are resolved
--  client-side: this package prepends the default volume (RD0,
--  settable via Set_Default_Volume) — the seed of a PATH resolver.
--
--  Reads are stateless (no fids, no close). The read buffer is a
--  client-owned memory object (Buf_Pages pages) transferred with
--  each Read call; the server maps it into its own address space
--  (the transferred cap pins the frames) and copies file bytes into
--  it. Open allocates and maps the buffer at Buffer_VA on first
--  success.

package Akernel_User.Files is
   use type Syscalls.U64;

   subtype U64 is Syscalls.U64;

   Op_Set_Name : constant U64 := 0;
   Op_Stat     : constant U64 := 1;
   Op_Open     : constant U64 := 2;
   Op_Read     : constant U64 := 3;
   Op_Mount    : constant U64 := 4;

   Status_Ok           : constant U64 := 0;
   Status_Not_Found    : constant U64 := 1;
   Status_Not_Ready    : constant U64 := 2;
   Status_Bad_Args     : constant U64 := 3;
   Status_Out_Of_Range : constant U64 := 4;

   Buf_Pages : constant U64 := 8;  --  32 KiB client read buffer
   Max_Name  : constant := 32;

   --  Client side: fixed VA window for the read buffer.
   Buffer_VA : constant U64 := 16#4400_0000#;

   --  Bind the package to a file-server endpoint cap (Send right).
   procedure Bind (FS_Cap : U64);

   --  Default volume for unqualified names (initially "RD0").
   procedure Set_Default_Volume (Name : String);

   --  Stat/Open return a protocol status; Open also allocates and
   --  maps the read buffer on first success.
   function Stat (Name : String; Size : out U64) return U64;
   function Open (Name : String; Size : out U64) return U64;

   --  Read Length bytes at Offset into Dest; Count returns the
   --  bytes actually read (clamped at EOF and buffer capacity).
   --  Requires a prior successful Open.
   function Read
     (Name   : String;
      Offset : U64;
      Dest   : System.Address;
      Length : U64;
      Count  : out U64) return U64;

end Akernel_User.Files;
