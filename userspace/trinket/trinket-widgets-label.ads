--  Label (milestone 56): static text, optionally an inset field
--  (sunken bevel + pane background — the mockup's path gadget
--  look).
package Trinket.Widgets.Label is

   type Alignment is (Left, Center);

   type Label is new Widget with record
      Txt       : String (1 .. Max_Text);
      Len       : Text_Len := 0;
      Align     : Alignment := Left;
      Inset     : Boolean := False;
   end record;
   function New_Label
     (S : String; Align : Alignment := Left; Inset : Boolean := False)
      return Any_Widget;
   overriding procedure Draw (W : Label; C : Canvas);
   overriding procedure Min_Size (W : Label; MW, MH : out U64);
   procedure Set_Text (W : in out Label; S : String);
   --  Update an existing label's text and mark it dirty.

end Trinket.Widgets.Label;
