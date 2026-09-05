--  Separator (M87d): etched horizontal rule — a Bevel_Lo line
--  with a Bevel_Hi line directly under it (the frame groove
--  look). Pure decoration: no input, Min_Size 0x2, and its
--  weight only stretches the gaps around the lines.
package Trinket.Widgets.Separator is

   type Separator is new Widget with null record;
   function New_Separator return Any_Widget;
   overriding procedure Draw (W : Separator; C : Canvas);
   overriding procedure Min_Size (W : Separator; MW, MH : out U64);

end Trinket.Widgets.Separator;
