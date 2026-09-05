--  Gauge (M87a): progress bar — sunken frame, accent fill
--  left->right, optional centered NN% label drawn light on the
--  fill and dark on the empty half (Workbench fuelgauge
--  lineage). Pure display: no pointer/key handling.
package Trinket.Widgets.Gauge is

   type Gauge is new Widget with record
      Num      : U64 := 0;
      Den      : U64 := 100;
      Show_Pct : Boolean := True;
   end record;
   function New_Gauge (Show_Pct : Boolean := True) return Any_Widget;
   procedure Set_Fraction (W : in out Gauge; Num, Den : U64);
   --  Den = 0 is treated as 1; Num is clamped to Den. Marks
   --  dirty only when the rendered pixels actually change.
   overriding procedure Draw (W : Gauge; C : Canvas);
   overriding procedure Min_Size (W : Gauge; MW, MH : out U64);

end Trinket.Widgets.Gauge;
