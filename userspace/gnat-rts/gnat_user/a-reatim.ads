------------------------------------------------------------------------------
--                                                                          --
--                         GNAT RUN-TIME COMPONENTS                         --
--                                                                          --
--                         A D A . R E A L _ T I M E                        --
--                                                                          --
--                                 S p e c                                  --
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

--  Akernel version (milestone 53a): the RM interface without the native
--  spec's tasking with (System.Task_Primitives.Operations). Clock reads
--  the riscv time CSR directly (U-mode allowed via scounteren, kernel
--  milestone-53a init); qemu virt timebase is 10 MHz, so a tick is 100 ns.

package Ada.Real_Time is

   pragma Compile_Time_Error
     (Duration'Size /= 64,
      "this version of Ada.Real_Time requires 64-bit Duration");

   type Time is private;
   Time_First : constant Time;
   Time_Last  : constant Time;
   Time_Unit  : constant := 10#1.0#E-9;

   type Time_Span is private;
   Time_Span_First : constant Time_Span;
   Time_Span_Last  : constant Time_Span;
   Time_Span_Zero  : constant Time_Span;
   Time_Span_Unit  : constant Time_Span;

   Tick : constant Time;

   function Clock return Time;

   function "+"  (Left : Time;      Right : Time_Span) return Time;
   function "+"  (Left : Time_Span; Right : Time)      return Time;
   function "-"  (Left : Time;      Right : Time_Span) return Time;
   function "-"  (Left : Time;      Right : Time)      return Time_Span;

   function "<"  (Left, Right : Time) return Boolean;
   function "<=" (Left, Right : Time) return Boolean;
   function ">"  (Left, Right : Time) return Boolean;
   function ">=" (Left, Right : Time) return Boolean;

   function "+"  (Left, Right : Time_Span) return Time_Span;
   function "-"  (Left, Right : Time_Span) return Time_Span;
   function "-"  (Right : Time_Span)       return Time_Span;
   function "abs" (Right : Time_Span)      return Time_Span;

   function "<"  (Left, Right : Time_Span) return Boolean;
   function "<=" (Left, Right : Time_Span) return Boolean;
   function ">"  (Left, Right : Time_Span) return Boolean;
   function ">=" (Left, Right : Time_Span) return Boolean;

   function "*" (Left : Time_Span; Right : Integer) return Time_Span;
   function "*" (Left : Integer; Right : Time_Span) return Time_Span;

   function "/" (Left, Right : Time_Span) return Integer;
   function "/" (Left : Time_Span; Right : Integer) return Time_Span;

   type Seconds_Count is new Long_Long_Integer;
   --  Seconds_Count needs 64 bits, since the type Time has the full
   --  range of a 64-bit count (the GNAT convention; no day wrap).

   procedure Split (T : Time; SC : out Seconds_Count; TS : out Time_Span);

   function Time_Of (SC : Seconds_Count; TS : Time_Span := Time_Span_Zero)
                     return Time;

   function To_Duration   (TS : Time_Span) return Duration;
   function To_Time_Span  (D : Duration)   return Time_Span;

   function Nanoseconds  (MS : Integer) return Time_Span;
   function Microseconds (US : Integer) return Time_Span;
   function Milliseconds (MS : Integer) return Time_Span;
   function Seconds      (S  : Integer) return Time_Span;
   function Minutes      (M  : Integer) return Time_Span;

private

   --  Both types are nanosecond counts in a 64-bit signed integer.
   --  Clock is the riscv time CSR scaled from 10 MHz ticks, i.e. ns
   --  since boot; arithmetic overflows silently like every bare-board
   --  implementation (checks are suppressed in the runtime).

   type Time is new Long_Long_Integer;

   Time_First : constant Time := Time'First;
   Time_Last  : constant Time := Time'Last;

   type Time_Span is new Long_Long_Integer;

   Time_Span_First : constant Time_Span := Time_Span'First;
   Time_Span_Last  : constant Time_Span := Time_Span'Last;
   Time_Span_Zero  : constant Time_Span := 0;
   Time_Span_Unit  : constant Time_Span := 1;

   --  qemu virt timebase: 10 MHz, one CSR tick is 100 ns.
   Tick : constant Time := 100;

end Ada.Real_Time;
