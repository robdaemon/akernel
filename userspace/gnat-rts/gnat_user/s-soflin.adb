------------------------------------------------------------------------------
--                                                                          --
--                         GNAT RUN-TIME COMPONENTS                         --
--                                                                          --
--                    S Y S T E M . S O F T _ L I N K S                     --
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
--  bare-board body, which withs System.Tasking + System.Task_Primitives.
--  Under No_Tasking the soft links keep their classic single-thread
--  semantics: locks are no-ops and the current exception is one
--  environment-thread occurrence. When tasking lands (the s-taprop
--  milestone) this body is replaced by real soft links again.

package body System.Soft_Links is

   Current_Excep : aliased EO;
   --  The environment thread's exception occurrence storage

   --------------------
   -- Task_Lock_Soft --
   --------------------

   procedure Task_Lock_Soft is
   begin
      null;
   end Task_Lock_Soft;

   ----------------------
   -- Task_Unlock_Soft --
   ----------------------

   procedure Task_Unlock_Soft is
   begin
      null;
   end Task_Unlock_Soft;

   --------------------
   -- Adafinal_Soft --
   --------------------

   procedure Adafinal_Soft is
   begin
      --  Finalization of the runtime happens through the binder's
      --  adafinal; programs leave via the Process_Exit syscall.
      null;
   end Adafinal_Soft;

   ---------------------------
   -- Get_Current_Excep_Soft --
   ---------------------------

   function Get_Current_Excep_Soft return EOA is
   begin
      return Current_Excep'Access;
   end Get_Current_Excep_Soft;

   -------------------------
   -- Get_GNAT_Exception --
   -------------------------

   function Get_GNAT_Exception return Ada.Exceptions.Exception_Id is
   begin
      return Ada.Exceptions.Exception_Identity (Get_Current_Excep.all.all);
   end Get_GNAT_Exception;

   ----------------------------
   -- Task_Termination_Soft --
   ----------------------------

   procedure Task_Termination_Soft (Except : EO) is
      pragma Unreferenced (Except);
   begin
      null;
   end Task_Termination_Soft;

   -----------------------------
   -- Acquire_RTS_Lock_Soft --
   -----------------------------

   procedure Acquire_RTS_Lock_Soft (Addr : Address) is
      pragma Unreferenced (Addr);
   begin
      null;
   end Acquire_RTS_Lock_Soft;

   -----------------------------
   -- Release_RTS_Lock_Soft --
   -----------------------------

   procedure Release_RTS_Lock_Soft (Addr : Address) is
      pragma Unreferenced (Addr);
   begin
      null;
   end Release_RTS_Lock_Soft;

   -------------------------------
   -- Save_Library_Occurrence --
   -------------------------------

   procedure Save_Library_Occurrence (E : EOA) is
      use Ada.Exceptions;
   begin
      if not Library_Exception_Set then
         Library_Exception_Set := True;
         if E /= null then
            Ada.Exceptions.Save_Occurrence (Library_Exception, E.all);
         end if;
      end if;
   end Save_Library_Occurrence;

end System.Soft_Links;
