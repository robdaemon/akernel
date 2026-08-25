--  Scripting.Console_IO (milestone 70 chunk 4): a blocking
--  console line reader for hosts that own the raw console
--  stream (the shell's `ask`). Op_Read cannot block (the
--  terminal is a single-threaded receiver), so poll with
--  yields between drains — the shell prompt loop's discipline.
--  Programs with a stdin trailer (C:Execute) use
--  Akernel_User.CLI.Get_Line instead.
package Scripting.Console_IO is

   --  Read one CR/LF-terminated line (BS/DEL erase, echo is the
   --  console device's job). Bounded by Buf; Len is the line
   --  length (0 on a bare return or a dead console).
   procedure Read_Line (Buf : out String; Len : out Natural);

end Scripting.Console_IO;
