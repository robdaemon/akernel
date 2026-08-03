with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Device_Tree;

package body Device_Manager is
   use Akernel_User.Syscalls;
   use type U64;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_8;
   use type Device_Tree.Status;

   subtype U32 is Interfaces.Unsigned_32;

   Max_Lines       : constant := 8;
   Max_Token       : constant := 64;
   First_Driver_Id : constant U64 := 16;

   DTB_VA   : constant U64 := 16#5600_0000#;
   Probe_VA : constant U64 := 16#5640_0000#;

   type Probe_Kind is (Probe_None, Probe_Virtio);

   type Driver_Line is record
      Compatible : String (1 .. Max_Token) := (others => Character'Val (0));
      Compat_Len : Natural := 0;
      Path       : String (1 .. Max_Token) := (others => Character'Val (0));
      Path_Len   : Natural := 0;
      Probe      : Probe_Kind := Probe_None;
      Class_Id   : U32 := 0;
   end record;

   Lines      : array (1 .. Max_Lines) of Driver_Line;
   Line_Count : Natural := 0;

   Console_Handle  : U64 := 0;
   Resource_Handle : U64 := 0;
   Block_EP        : U64 := 0;

   function Block_Service return U64 is (Block_EP);
   Next_Id         : U64 := First_Driver_Id;

   function Shl (Value : U64; Amount : Natural) return U64
     renames Interfaces.Shift_Left;

   ------------------------------------------------------------------
   --  System/Drivers parsing (byte API, same shape as the manifest)
   ------------------------------------------------------------------

   DB_Cap  : U64 := 0;
   DB_Size : U64 := 0;

   function DB_Byte (Offset : U64) return Character is
      Raw : constant U64 := Boot_Read_Byte (DB_Cap, Offset);
   begin
      if Raw > 255 then
         return Character'Val (0);
      end if;
      return Character'Val (Natural (Raw));
   end DB_Byte;

   function Is_Space (C : Character) return Boolean is
   begin
      return C = ' ' or else C = Character'Val (9);
   end Is_Space;

   procedure Next_Token
     (Line_End  : U64;
      Pos       : in out U64;
      Token     : out String;
      Length    : out Natural;
      Available : out Boolean)
   is
      C : Character;
   begin
      Length := 0;
      Available := False;

      while Pos < Line_End loop
         C := DB_Byte (Pos);
         exit when not Is_Space (C);
         Pos := Pos + 1;
      end loop;

      if Pos >= Line_End then
         return;
      end if;

      Available := True;
      while Pos < Line_End loop
         C := DB_Byte (Pos);
         exit when Is_Space (C);

         if Length < Token'Length then
            Length := Length + 1;
            Token (Length) := C;
         end if;

         Pos := Pos + 1;
      end loop;
   end Next_Token;

   function Token_Equals
     (Token : String; Length : Natural; Value : String) return Boolean
   is
   begin
      return Length = Value'Length
        and then Token (1 .. Length) = Value;
   end Token_Equals;

   function Parse_U32
     (Token : String; Length : Natural; Valid : out Boolean) return U32
   is
      Value : U32 := 0;
      C     : Character;
   begin
      Valid := Length > 0;
      for Index in 1 .. Length loop
         C := Token (Index);
         if C < '0' or else C > '9' then
            Valid := False;
            return 0;
         end if;
         Value := Value * 10
           + U32 (Character'Pos (C) - Character'Pos ('0'));
      end loop;
      return Value;
   end Parse_U32;

   procedure Parse_DB is
      Line_Start : U64 := 0;
      Line_End   : U64;
      Pos        : U64;
      C          : Character;
      Token      : String (1 .. Max_Token) := (others => ' ');
      Length     : Natural;
      Have       : Boolean;
      Valid      : Boolean;
   begin
      while Line_Start < DB_Size loop
         Line_End := Line_Start;
         while Line_End < DB_Size loop
            C := DB_Byte (Line_End);
            exit when C = Character'Val (10) or else C = Character'Val (13);
            Line_End := Line_End + 1;
         end loop;

         Pos := Line_Start;
         Next_Token (Line_End, Pos, Token, Length, Have);

         if Have
           and then not Token_Equals (Token, Length, "#")
           and then Token_Equals (Token, Length, "driver")
           and then Line_Count < Max_Lines
         then
            Line_Count := Line_Count + 1;
            declare
               L : Driver_Line renames Lines (Line_Count);
            begin
               Next_Token (Line_End, Pos, Token, Length, Have);
               if Have then
                  L.Compatible := (others => Character'Val (0));
                  L.Compatible (1 .. Length) := Token (1 .. Length);
                  L.Compat_Len := Length;
               end if;

               Next_Token (Line_End, Pos, Token, Length, Have);
               if Have then
                  L.Path := (others => Character'Val (0));
                  L.Path (1 .. Length) := Token (1 .. Length);
                  L.Path_Len := Length;
               end if;

               Next_Token (Line_End, Pos, Token, Length, Have);
               if Have
                 and then Token_Equals (Token, Length, "virtio")
               then
                  L.Probe := Probe_Virtio;
               end if;

               Next_Token (Line_End, Pos, Token, Length, Have);
               if Have then
                  L.Class_Id := Parse_U32 (Token, Length, Valid);
               end if;
            end;
         end if;

         Line_Start := Line_End + 1;
         while Line_Start < DB_Size loop
            C := DB_Byte (Line_Start);
            exit when C /= Character'Val (10)
              and then C /= Character'Val (13);
            Line_Start := Line_Start + 1;
         end loop;
      end loop;
   end Parse_DB;

   ------------------------------------------------------------------
   --  Probing + spawning
   ------------------------------------------------------------------

   type Reg_File is array (U64 range 0 .. 1023) of U32
     with Volatile_Components;

   Probe_Regs : Reg_File
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (Probe_VA));

   procedure Log (S : String) is
   begin
      Debug_Put_Line (S);
   end Log;

   --  Spawn the driver for one probed instance. MMIO_Cap is the
   --  io_map object already created for probing; IRQ_Source 0 means
   --  the node carries no interrupts.
   procedure Spawn_Driver
     (Line_Index : Positive;
      MMIO_Cap   : U64;
      IRQ_Source : U64)
   is
      L : Driver_Line renames Lines (Line_Index);
      Image_Cap   : constant U64 := Boot_Cap (L.Path (1 .. L.Path_Len));
      Grant_Count : U64 := 0;
      IRQ_Cap     : U64;
      Svc_EP      : U64;
      Process_Cap : U64;
      Result      : U64;
   begin
      if Image_Cap = 0 then
         Log ("devmgr: driver image unknown");
         return;
      end if;

      --  Handle 1 is the console endpoint: class 0 is the console
      --  server itself and receives on it; every other driver gets
      --  a Send side badged with its driver id (line-atomic console
      --  writes keyed by badge).
      if L.Class_Id = 0 then
         Set_Grant (Grant_Count, Console_Handle, Right_Receive, 0);
      else
         Set_Grant (Grant_Count, Console_Handle, Right_Send, Next_Id);
      end if;
      Grant_Count := Grant_Count + 1;
      Set_Grant (Grant_Count, MMIO_Cap,
                 Right_Map + Right_Read + Right_Write, 0);
      Grant_Count := Grant_Count + 1;

      if IRQ_Source /= 0 then
         IRQ_Cap := IRQ_Create (Resource_Handle, IRQ_Source);
         if IRQ_Cap = Syscall_Failed then
            Log ("devmgr: irq_create failed");
            return;
         end if;

         Set_Grant (Grant_Count, IRQ_Cap,
                    Right_Wait + Right_Ack, 0);
         Grant_Count := Grant_Count + 1;
      end if;

      --  Per-instance service endpoint: init keeps the Send side,
      --  the driver receives on handle 4 (or 3 when the node had
      --  no interrupts — all current virtio nodes do).
      Svc_EP := EP_Create;
      if Svc_EP = Syscall_Failed then
         Log ("devmgr: ep_create failed");
         return;
      end if;

      Set_Grant (Grant_Count, Svc_EP, Right_Receive, 0);
      Grant_Count := Grant_Count + 1;

      Result := Spawn (Image_Cap, Grant_Count, Process_Cap);
      if Result = Spawn_Ok and then Process_Cap /= 0 then
         Next_Id := Next_Id + 1;
         if L.Class_Id = 2 and then Block_EP = 0 then
            Block_EP := Svc_EP;
         end if;
         Log ("devmgr: spawned " & L.Path (1 .. L.Path_Len));
      else
         Log ("devmgr: driver spawn failed");
      end if;
   end Spawn_Driver;

   --  Map the node's registers into init, run the line's probe, and
   --  on match spawn the driver. MMIO caps are per-instance.
   procedure Handle_Node (Info : Device_Tree.Node_Info) is
      MMIO_Cap : U64;
      Map_Len  : U64;
      Result   : U64;
   begin
      if Info.Base = 0 then
         return;
      end if;

      for I in 1 .. Line_Count loop
         declare
            L : Driver_Line renames Lines (I);
            Matches : Boolean := False;
         begin
            for C in 1 .. Info.Compatible_Count loop
               if Info.Compatibles (C).Length = L.Compat_Len
                 and then Info.Compatibles (C).Text (1 .. L.Compat_Len) =
                   L.Compatible (1 .. L.Compat_Len)
               then
                  Matches := True;
                  exit;
               end if;
            end loop;

            if Matches then
               Map_Len := (Info.Size + 4095) / 4096 * 4096;
               if Map_Len = 0 then
                  Map_Len := 4096;
               end if;

               MMIO_Cap := IO_Map (Resource_Handle, Info.Base, Map_Len);
               if MMIO_Cap = Syscall_Failed then
                  Log ("devmgr: io_map failed");
                  return;
               end if;

               case L.Probe is
                  when Probe_None =>
                     Spawn_Driver (I, MMIO_Cap, Info.IRQ);

                  when Probe_Virtio =>
                     Result := Map_MMIO
                       (Address_Space => Address_Space_Cap,
                        Cap           => MMIO_Cap,
                        VA            => Probe_VA,
                        Offset        => 0,
                        Length        => 4096,
                        Flags         => 3);
                     if Result /= 0 then
                        Log ("devmgr: probe map failed");
                        return;
                     end if;

                     declare
                        Device_Id : constant U32 := Probe_Regs (2);
                     begin
                        Result := Mem_Unmap
                          (Address_Space_Cap, Probe_VA, 4096);

                        if Device_Id = L.Class_Id then
                           Spawn_Driver (I, MMIO_Cap, Info.IRQ);
                        end if;
                     end;
               end case;
            end if;
         end;
      end loop;
   end Handle_Node;

   ------------------------------------------------------------------

   procedure Run (Console_EP : U64) is
      DTB_Cap    : U64;
      DTB_Size   : U64;
      Lead_In    : U64;
      Result     : U64;
      DTB_Status : Device_Tree.Status;
   begin
      Console_Handle := Console_EP;
      Resource_Handle := Boot_Cap ("device_resource");
      DTB_Cap := Boot_Cap ("dtb");
      DB_Cap := Boot_Cap ("System/Drivers");

      if Resource_Handle = 0 or else DTB_Cap = 0 or else DB_Cap = 0 then
         Log ("devmgr: missing device_resource/dtb/System/Drivers");
         return;
      end if;

      DB_Size := Boot_File_Size (DB_Cap);
      Parse_DB;

      if Line_Count = 0 then
         Log ("devmgr: empty driver database");
         return;
      end if;

      DTB_Size := Boot_File_Size (DTB_Cap);

      --  First page to learn the lead-in, then the true page span
      --  (mem_map lengths must be page-aligned).
      Result := Mem_Map_File
        (Address_Space => Address_Space_Cap,
         Cap           => DTB_Cap,
         VA            => DTB_VA,
         Offset        => 0,
         Length        => 4096,
         Lead_In       => Lead_In);
      if Result = 0 then
         declare
            Pages : constant U64 :=
              (Lead_In + DTB_Size + 4095) / 4096;
         begin
            if Pages > 1 then
               Result := Mem_Map_File
                 (Address_Space => Address_Space_Cap,
                  Cap           => DTB_Cap,
                  VA            => DTB_VA + 4096,
                  Offset        => 4096,
                  Length        => (Pages - 1) * 4096,
                  Lead_In       => Lead_In);
            end if;
         end;
      end if;

      if Result /= 0 then
         Log ("devmgr: dtb map failed");
         return;
      end if;

      Device_Tree.Walk
        (Base    => DTB_VA + Lead_In,
         On_Node => Handle_Node'Access,
         Result  => DTB_Status);

      if DTB_Status /= Device_Tree.Ok then
         if DTB_Status = Device_Tree.Bad_Magic then
            Log ("devmgr: dtb walk bad magic");
         else
            Log ("devmgr: dtb walk unsupported format");
         end if;
      end if;
   end Run;
end Device_Manager;
