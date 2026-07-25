package Board.PLIC is
   type Source_Id is new Natural range 0 .. 1023;

   No_Source    : constant Source_Id := 0;
   UART0_Source : constant Source_Id := 10;

   procedure Initialize;
   procedure Enable (Source : Source_Id);
   function Claim return Source_Id;
   procedure Complete (Source : Source_Id);
end Board.PLIC;
