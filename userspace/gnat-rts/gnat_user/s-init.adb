------------------------------------------------------------------------------
--                                                                          --
--                         GNAT RUN-TIME COMPONENTS                         --
--                                                                          --
--                          S Y S T E M . I N I T                           --
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

--  Akernel non-tasking body (milestone 53a): the pool ships the Ravenscar
--  bare-board body (System.BB.CPU_Primitives + System.Tasking). We have
--  no signal handlers to install (traps belong to the kernel) and no
--  tasking runtime to initialize, so every entry is a no-op. The binder
--  still calls __gnat_runtime_initialize / __gnat_finalize around
--  package elaboration; Process_Exit never returns to either.

package body System.Init is

   procedure Initialize is null;
   pragma Export (C, Initialize, "__gnat_initialize");

   procedure Finalize is null;
   pragma Export (C, Finalize, "__gnat_finalize");

   ---------------------
   -- Install_Handler --
   ---------------------

   procedure Install_Handler is
   begin
      null;
   end Install_Handler;

   ------------------------
   -- Runtime_Initialize --
   ------------------------

   procedure Runtime_Initialize (Install_Handler : Integer) is
      pragma Unreferenced (Install_Handler);
   begin
      null;
   end Runtime_Initialize;

   ----------------------
   -- Runtime_Finalize --
   ----------------------

   procedure Runtime_Finalize is
   begin
      null;
   end Runtime_Finalize;

end System.Init;
