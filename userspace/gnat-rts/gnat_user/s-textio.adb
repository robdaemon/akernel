------------------------------------------------------------------------------
--                                                                          --
--                         GNAT RUN-TIME COMPONENTS                         --
--                                                                          --
--                        S Y S T E M . T E X T _ I O                       --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--          Copyright (C) 1992-2025, Free Software Foundation, Inc.         --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that  it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.                                     --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
------------------------------------------------------------------------------

--  Akernel body (milestone 53a): the pool ships the PolarFire MMIO-UART
--  body, but a userspace process has no UART — runtime diagnostics
--  (System.IO, the last-chance handler's exception dump) ride the
--  kernel debug-putchar syscall, which needs no IPC and works in any
--  rendezvous state (the established server-diagnostics rule).

package body System.Text_IO is

   procedure Debug_Putchar (C : Character)
     with Import, Convention => C,
          External_Name => "akernel_sys_debug_putchar";

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      Initialized := True;
   end Initialize;

   -----------------
   -- Is_Rx_Ready --
   -----------------

   function Is_Rx_Ready return Boolean is
   begin
      return False;  --  no stdin at this layer
   end Is_Rx_Ready;

   -----------------
   -- Is_Tx_Ready --
   -----------------

   function Is_Tx_Ready return Boolean is
   begin
      return True;   --  the kernel console buffer never blocks
   end Is_Tx_Ready;

   ---------
   -- Get --
   ---------

   function Get return Character is
   begin
      return ASCII.NUL;  --  no stdin at this layer
   end Get;

   ---------
   -- Put --
   ---------

   procedure Put (C : Character) is
   begin
      Debug_Putchar (C);
   end Put;

   ----------------------------
   -- Use_Cr_Lf_For_New_Line --
   ----------------------------

   function Use_Cr_Lf_For_New_Line return Boolean is
   begin
      return False;  --  the kernel debug console expands LF itself
   end Use_Cr_Lf_For_New_Line;

end System.Text_IO;
