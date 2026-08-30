------------------------------------------------------------------------------
--                                                                          --
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--     G N A T . S O C K E T S . T H I N . S o c k e t _ E r r o r _ M e  --
--                            s s a g e                                     --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--          Copyright (C) 2007-2025, Free Software Foundation, Inc.         --
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
-- version 3.1, as published by the GCC Runtime Library Exception.          --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
-- GNAT was originally developed  by the GNAT team at  New York University. --
-- Extensive contributions were provided by Ada Core Technologies Inc.      --
--                                                                          --
------------------------------------------------------------------------------

--  This is the default implementation of this unit, using the standard C
--  library's strerror(3) function. It is used on all platforms except
--  Windows, since on that platform socket errno values are distinct from
--  the system ones: there is a specific variant of this function in
--  g-socthi-mingw.adb.

--  AKERNEL (m73): GNAT.OS_Lib (the usual source of Errno_Message) is not
--  vendored in this runtime; import newlib's strerror directly.

with Interfaces.C.Strings; use Interfaces.C.Strings;

separate (GNAT.Sockets.Thin)

--------------------------
-- Socket_Error_Message --
--------------------------

function Socket_Error_Message
  (Errno : Integer) return String
is
   function C_Strerror (Code : C.int) return chars_ptr
     with Import, Convention => C, External_Name => "strerror";

   P : constant chars_ptr := C_Strerror (C.int (Errno));

begin
   if P = Null_Ptr then
      return "Unknown system error";
   end if;
   return Value (P);
end Socket_Error_Message;
