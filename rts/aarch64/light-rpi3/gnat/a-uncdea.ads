------------------------------------------------------------------------------
--                                                                          --
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--           A D A . U N C H E C K E D _ D E A L L O C A T I O N            --
--                                                                          --
--                                 S p e c                                  --
--                                                                          --
-- This specification is derived from the Ada Reference Manual for use with --
-- GNAT.  In accordance with the copyright of that document, you can freely --
-- copy and modify this specification,  provided that if you redistribute a --
-- modified version,  any changes that you have made are clearly indicated. --
--                                                                          --
------------------------------------------------------------------------------

generic
   type Object (<>) is limited private;
   type Name is access Object;

procedure Ada.Unchecked_Deallocation (X : in out Name) with
  Depends => (X    => null,  --  X on exit does not depend on its input value
              null => X),    --  X's input value has no effect
  Post => X = null;          --  X's output value is null
pragma Preelaborate (Unchecked_Deallocation);

pragma Import (Intrinsic, Ada.Unchecked_Deallocation);
