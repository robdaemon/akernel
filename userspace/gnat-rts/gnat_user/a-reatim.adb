------------------------------------------------------------------------------
--                                                                          --
--                         GNAT RUN-TIME COMPONENTS                         --
--                                                                          --
--                         A D A . R E A L _ T I M E                        --
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

--  Akernel version (milestone 53a): Clock = riscv time CSR x 100 ns.
--  The kernel enables U-mode counter reads via scounteren at boot
--  (Arch.SBI.Enable_User_Counters); qemu virt runs the timebase at
--  10 MHz. All arithmetic goes through Long_Long_Integer explicitly:
--  with two related derived numeric types in scope, bare mixed
--  conversions are ambiguous.

package body Ada.Real_Time is

   subtype LLI is Long_Long_Integer;

   function Rdtime return LLI
     with Import, Convention => C, External_Name => "akernel_rdtime";

   Ns_Per_Sec : constant := 1_000_000_000;

   ---------
   -- "<" --
   ---------

   function "<" (Left, Right : Time) return Boolean is
   begin
      return LLI (Left) < LLI (Right);
   end "<";

   function "<" (Left, Right : Time_Span) return Boolean is
   begin
      return LLI (Left) < LLI (Right);
   end "<";

   ----------
   -- "<=" --
   ----------

   function "<=" (Left, Right : Time) return Boolean is
   begin
      return LLI (Left) <= LLI (Right);
   end "<=";

   function "<=" (Left, Right : Time_Span) return Boolean is
   begin
      return LLI (Left) <= LLI (Right);
   end "<=";

   ---------
   -- ">" --
   ---------

   function ">" (Left, Right : Time) return Boolean is
   begin
      return LLI (Left) > LLI (Right);
   end ">";

   function ">" (Left, Right : Time_Span) return Boolean is
   begin
      return LLI (Left) > LLI (Right);
   end ">";

   ----------
   -- ">=" --
   ----------

   function ">=" (Left, Right : Time) return Boolean is
   begin
      return LLI (Left) >= LLI (Right);
   end ">=";

   function ">=" (Left, Right : Time_Span) return Boolean is
   begin
      return LLI (Left) >= LLI (Right);
   end ">=";

   -----------
   -- Clock --
   -----------

   function Clock return Time is
   begin
      return Time (Rdtime * 100);
   end Clock;

   ---------
   -- "+" --
   ---------

   function "+" (Left : Time; Right : Time_Span) return Time is
   begin
      return Time (LLI (Left) + LLI (Right));
   end "+";

   function "+" (Left : Time_Span; Right : Time) return Time is
   begin
      return Time (LLI (Left) + LLI (Right));
   end "+";

   function "+" (Left, Right : Time_Span) return Time_Span is
   begin
      return Time_Span (LLI (Left) + LLI (Right));
   end "+";

   ---------
   -- "-" --
   ---------

   function "-" (Left : Time; Right : Time_Span) return Time is
   begin
      return Time (LLI (Left) - LLI (Right));
   end "-";

   function "-" (Left, Right : Time) return Time_Span is
   begin
      return Time_Span (LLI (Left) - LLI (Right));
   end "-";

   function "-" (Left, Right : Time_Span) return Time_Span is
   begin
      return Time_Span (LLI (Left) - LLI (Right));
   end "-";

   function "-" (Right : Time_Span) return Time_Span is
   begin
      return Time_Span (-LLI (Right));
   end "-";

   -----------
   -- "abs" --
   -----------

   function "abs" (Right : Time_Span) return Time_Span is
   begin
      return Time_Span (abs LLI (Right));
   end "abs";

   ---------
   -- "*" --
   ---------

   function "*" (Left : Time_Span; Right : Integer) return Time_Span is
   begin
      return Time_Span (LLI (Left) * LLI (Right));
   end "*";

   function "*" (Left : Integer; Right : Time_Span) return Time_Span is
   begin
      return Time_Span (LLI (Left) * LLI (Right));
   end "*";

   ---------
   -- "/" --
   ---------

   function "/" (Left, Right : Time_Span) return Integer is
   begin
      return Integer (LLI (Left) / LLI (Right));
   end "/";

   function "/" (Left : Time_Span; Right : Integer) return Time_Span is
   begin
      return Time_Span (LLI (Left) / LLI (Right));
   end "/";

   -----------
   -- Split --
   -----------

   procedure Split (T : Time; SC : out Seconds_Count; TS : out Time_Span)
   is
   begin
      --  GNAT convention: Seconds_Count is unbounded (no day wrap).
      SC := Seconds_Count (LLI (T) / Ns_Per_Sec);
      TS := Time_Span (LLI (T) mod Ns_Per_Sec);
   end Split;

   -------------
   -- Time_Of --
   -------------

   function Time_Of
     (SC : Seconds_Count; TS : Time_Span := Time_Span_Zero) return Time is
   begin
      return Time (LLI (SC) * Ns_Per_Sec + LLI (TS));
   end Time_Of;

   -----------------
   -- To_Duration --
   -----------------

   function To_Duration (TS : Time_Span) return Duration is
   begin
      --  Duration'Small is 10**-9 with a 64-bit Duration, so this is
      --  exact for any representable value.
      return Duration (LLI (TS)) / Ns_Per_Sec;
   end To_Duration;

   ------------------
   -- To_Time_Span --
   ------------------

   function To_Time_Span (D : Duration) return Time_Span is
   begin
      --  D * Ns_Per_Sec is a Duration whose integer part is ns;
      --  conversion rounds to nearest (RM 4.6).
      return Time_Span (LLI (D * Ns_Per_Sec));
   end To_Time_Span;

   ------------------
   -- Nanoseconds --
   ------------------

   function Nanoseconds (MS : Integer) return Time_Span is
   begin
      return Time_Span (MS);
   end Nanoseconds;

   ------------------
   -- Microseconds --
   ------------------

   function Microseconds (US : Integer) return Time_Span is
   begin
      return Time_Span (LLI (US) * 1_000);
   end Microseconds;

   ------------------
   -- Milliseconds --
   ------------------

   function Milliseconds (MS : Integer) return Time_Span is
   begin
      return Time_Span (LLI (MS) * 1_000_000);
   end Milliseconds;

   -------------
   -- Seconds --
   -------------

   function Seconds (S : Integer) return Time_Span is
   begin
      return Time_Span (LLI (S) * Ns_Per_Sec);
   end Seconds;

   -------------
   -- Minutes --
   -------------

   function Minutes (M : Integer) return Time_Span is
   begin
      return Time_Span (LLI (M) * (60 * Ns_Per_Sec));
   end Minutes;

end Ada.Real_Time;
