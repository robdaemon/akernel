with System.Machine_Code;

package body Trinket.App_Port is
   use type Trinket.U64;
   use type System.Address;

   protected body Head_Lock is
      procedure Put
        (Page         : System.Address;
         Code, A0, A1, A2 : U64;
         Ok           : out Boolean)
      is
         Q : Word_Array
           with Address => Page;
         Head : constant U64 := Q (0);
         Tail : constant U64 := Q (1);
         Slot : U64;
      begin
         if Head - Tail >= Max_Events then
            Ok := False;  --  full: drop-new (Bureau policy)
            return;
         end if;
         Slot := 2 + (Head mod Max_Events) * Slot_Words;
         Q (Slot)     := Code;
         Q (Slot + 1) := A0;
         Q (Slot + 2) := A1;
         Q (Slot + 3) := A2;
         Q (0)        := Head + 1;
         Ok := True;
      end Put;
   end Head_Lock;

   procedure Setup
     (P        : in out Port;
      Page     : System.Address;
      Ntfn_Cap : U64)
   is
      Q : Word_Array
        with Address => Page;
   begin
      P.Page     := Page;
      P.Ntfn_Cap := Ntfn_Cap;
      Q (0) := 0;
      Q (1) := 0;
   end Setup;

   function Post
     (P             : in out Port;
      Code, A0, A1, A2 : U64) return Boolean
   is
      use Akernel_User.Syscalls;
      Ok     : Boolean;
      Ignore : U64;
   begin
      if P.Page = System.Null_Address then
         return False;
      end if;
      P.Lock.Put (P.Page, Code, A0, A1, A2, Ok);
      if not Ok then
         return False;
      end if;
      --  Make the slot + head stores visible to the loop thread
      --  before the signal crosses the kernel boundary.
      System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
      Ignore := Ntfn_Signal (P.Ntfn_Cap, App_Signal_Bit);
      return True;
   end Post;

   procedure Drain
     (P         : in out Port;
      Cb        : Msg_Callback;
      Quit_Seen : out Boolean)
   is
      Q : Word_Array
        with Address => P.Page;
      Head : U64;
      Tail : U64;
      Slot : U64;
   begin
      Quit_Seen := False;
      if P.Page = System.Null_Address then
         return;
      end if;
      --  Pair with Post's fence: observe head, then read slots.
      System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
      Head := Q (0);
      Tail := Q (1);
      while Tail < Head loop
         Slot := 2 + (Tail mod Max_Events) * Slot_Words;
         if Q (Slot) = App_Code_Quit then
            Quit_Seen := True;
         elsif Cb /= null then
            Cb (Q (Slot), Q (Slot + 1), Q (Slot + 2), Q (Slot + 3));
         end if;
         Tail := Tail + 1;
      end loop;
      Q (1) := Tail;
   end Drain;

end Trinket.App_Port;
