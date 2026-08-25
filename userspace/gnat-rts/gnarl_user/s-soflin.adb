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
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.                                     --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GNU Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
-- GNAT was originally developed  by the Ada Core Technologies Inc.         --
--                                                                          --
------------------------------------------------------------------------------

--  Akernel Ravenscar tasking version of System.Soft_Links. This body is
--  selected when the tasking runtime project is built; it relies on the
--  low-level tasking primitives provided by System.OS_Interface and
--  System.Task_Primitives.Operations.

with System.Multiprocessors.Spin_Locks;
with System.OS_Interface;
with System.Tasking;
with System.Task_Primitives.Operations;

package body System.Soft_Links is

   use System.Task_Primitives.Operations;
   use type System.Tasking.Termination_Handler;

   ----------------------------
   -- Global lock (Akernel)  --
   ----------------------------

   --  Akernel M68: the vendored body relied on the priority ceiling
   --  alone for mutual exclusion, which only works on uniprocessor,
   --  and saved the caller's priority in one global variable, which
   --  races when two threads lock concurrently. The ceiling boost is
   --  kept (it bounds same-hart preemption), and a test-and-set spin
   --  lock with Yield backoff provides real cross-hart exclusion.
   --  The saved priority moved into the ATCB (per task).

   Global_Lock : System.Multiprocessors.Spin_Locks.Spin_Lock;

   ----------------------------
   -- Get_Current_Excep_Soft --
   ----------------------------

   function Get_Current_Excep_Soft return EOA is
   begin
      return Self.Common.Compiler_Data.Current_Excep'Access;
   end Get_Current_Excep_Soft;

   ------------------------
   -- Get_GNAT_Exception --
   ------------------------

   function Get_GNAT_Exception return Ada.Exceptions.Exception_Id is
   begin
      return Ada.Exceptions.Exception_Identity (Get_Current_Excep.all.all);
   end Get_GNAT_Exception;

   -----------------------------
   -- Save_Library_Occurrence --
   -----------------------------

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

   -------------------
   -- Adafinal_Soft --
   -------------------

   procedure Adafinal_Soft is
   begin
      Task_Termination_Handler.all (Ada.Exceptions.Null_Occurrence);
   end Adafinal_Soft;

   ----------------------
   -- Acquire_RTS_Lock --
   ----------------------

   procedure Acquire_RTS_Lock_Soft (Addr : Address) is
      pragma Unreferenced (Addr);
   begin
      Task_Lock_Soft;
   end Acquire_RTS_Lock_Soft;

   ----------------------
   -- Release_RTS_Lock --
   ----------------------

   procedure Release_RTS_Lock_Soft (Addr : Address) is
      pragma Unreferenced (Addr);
   begin
      Task_Unlock_Soft;
   end Release_RTS_Lock_Soft;

   --------------------
   -- Task_Lock_Soft --
   --------------------

   procedure Task_Lock_Soft is
      Self_Id : System.Tasking.Task_Id;

   begin
      if not Any_Tasks_Created then
         return;
      end if;

      Self_Id := Self;

      Self_Id.Common.Global_Task_Lock_Nesting :=
        Self_Id.Common.Global_Task_Lock_Nesting + 1;

      if Self_Id.Common.Global_Task_Lock_Nesting = 1 then
         declare
            Prio : constant System.Any_Priority := Get_Priority (Self_Id);

         begin
            --  Store caller's active priority so that it can be later
            --  restored when releasing the global lock (per task).

            Self_Id.Common.Global_Task_Lock_Priority := Prio;

            --  Increase priority to ceiling level

            Set_Priority (Self_Id, System.Any_Priority'Last);

            --  Cross-hart mutual exclusion: spin with Yield backoff
            --  so a same-priority holder on this hart gets to run.

            declare
               Succeeded : Boolean;
            begin
               loop
                  System.Multiprocessors.Spin_Locks.Try_Lock
                    (Global_Lock, Succeeded);
                  exit when Succeeded;
                  System.OS_Interface.Yield;
               end loop;
            end;
         end;
      end if;
   end Task_Lock_Soft;

   ---------------------------
   -- Task_Termination_Soft --
   ---------------------------

   procedure Task_Termination_Soft (Except : EO) is
      pragma Unreferenced (Except);

      Self_Id : System.Tasking.Task_Id;
      TH      : System.Tasking.Termination_Handler := null;

   begin
      if not Any_Tasks_Created then
         return;
      end if;

      Self_Id := Self;

      --  Raise the priority to prevent race conditions when using
      --  System.Tasking.Fall_Back_Handler.

      Set_Priority (Self_Id, Any_Priority'Last);

      TH := System.Tasking.Fall_Back_Handler;

      --  Restore original priority after retrieving shared data

      Set_Priority (Self_Id, Self_Id.Common.Base_Priority);

      --  Execute the task termination handler if we found it

      if TH /= null then
         TH.all (Self_Id);
      end if;
   end Task_Termination_Soft;

   ----------------------
   -- Task_Unlock_Soft --
   ----------------------

   procedure Task_Unlock_Soft is
      Self_Id : System.Tasking.Task_Id;

   begin
      if not Any_Tasks_Created then
         return;
      end if;

      Self_Id := Self;

      pragma Assert (Self_Id.Common.Global_Task_Lock_Nesting > 0);

      Self_Id.Common.Global_Task_Lock_Nesting :=
        Self_Id.Common.Global_Task_Lock_Nesting - 1;

      if Self_Id.Common.Global_Task_Lock_Nesting = 0 then

         --  Release the cross-hart lock, then restore the task's
         --  active priority.

         System.Multiprocessors.Spin_Locks.Unlock (Global_Lock);
         Set_Priority (Self_Id, Self_Id.Common.Global_Task_Lock_Priority);
      end if;
   end Task_Unlock_Soft;

end System.Soft_Links;
