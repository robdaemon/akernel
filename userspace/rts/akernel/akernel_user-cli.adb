with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.Syscalls;

package body Akernel_User.CLI is

   --  Args page staging + token table (library level: big buffers
   --  never live on the user stack).
   Args_Buf   : String (1 .. 4096) := (others => Character'Val (0));
   Args_Len   : Natural := 0;
   Args_Read  : Boolean := False;

   Max_Args   : constant := 64;
   type Slice is record
      First : Natural := 0;
      Last  : Natural := 0;  --  0/0 = empty
   end record;
   Tokens    : array (1 .. Max_Args) of Slice;
   Tok_Count : Natural := 0;

   procedure Parse_Args is
      I : Natural := 1;
      F : Natural;
   begin
      if Args_Read then
         return;
      end if;
      Args_Read := True;
      Syscalls.Read_Args (Args_Buf, Args_Len);
      while I <= Args_Len loop
         while I <= Args_Len and then Args_Buf (I) = ' ' loop
            I := I + 1;
         end loop;
         exit when I > Args_Len or else Tok_Count = Max_Args;
         F := I;
         while I <= Args_Len and then Args_Buf (I) /= ' ' loop
            I := I + 1;
         end loop;
         Tok_Count := Tok_Count + 1;
         Tokens (Tok_Count) := (First => F, Last => I - 1);
      end loop;
   end Parse_Args;

   function Arg_Count return Natural is
   begin
      Parse_Args;
      return Tok_Count;
   end Arg_Count;

   function Argument (Index : Positive) return String is
   begin
      Parse_Args;
      if Index > Tok_Count then
         return "";
      end if;
      return Args_Buf (Tokens (Index).First .. Tokens (Index).Last);
   end Argument;

   Env_Buf : String (1 .. 256);

   function Get_Env (Name : String) return String is
      Size  : U64 := 0;
      Count : U64 := 0;
      St    : U64;
   begin
      St := Files.Open ("ENV:" & Name, Size);
      if St /= Files.Status_Ok then
         return "";
      end if;
      Size := U64'Min (Size, U64 (Env_Buf'Length));
      St := Files.Read
        ("ENV:" & Name, 0, Env_Buf'Address, Size, Count);
      if St /= Files.Status_Ok or else Count = 0 then
         return "";
      end if;
      return Env_Buf (1 .. Natural (Count));
   end Get_Env;

   function Set_Env (Name : String; Value : String) return U64 is
      Count : U64 := 0;
      St    : U64;
   begin
      St := Files.Truncate ("ENV:" & Name);
      for I in Value'Range loop
         Env_Buf (I - Value'First + 1) := Value (I);
      end loop;
      --  Write creates the file when missing.
      return Files.Write
        ("ENV:" & Name, 0, Env_Buf'Address,
         U64 (Value'Length), Count);
   end Set_Env;

   procedure Fail_With (Message : String; Code : U64 := RC_Error) is
   begin
      Console.Put_Line (Message);
      Syscalls.Process_Exit (Code);
      loop
         Syscalls.Yield;  --  unreachable; keeps No_Return honest
      end loop;
   end Fail_With;

   procedure Exit_With (Code : U64 := RC_Ok) is
   begin
      Syscalls.Process_Exit (Code);
      loop
         Syscalls.Yield;
      end loop;
   end Exit_With;

end Akernel_User.CLI;
