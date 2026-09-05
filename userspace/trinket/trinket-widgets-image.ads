--  Image widget (milestone 63): a decoded Trinket.Images.Image
--  painted centered in its layout rect (clip does the rest).
--  The widget borrows the image — the app owns Load/Free.
with Trinket.Images;
package Trinket.Widgets.Image is

   type Image_Widget is new Widget with record
      Img : Trinket.Images.Image;
   end record;
   function New_Image (Img : Trinket.Images.Image) return Any_Widget;
   overriding procedure Draw (W : Image_Widget; C : Canvas);
   overriding procedure Min_Size (W : Image_Widget; MW, MH : out U64);
   procedure Set_Image (W : in out Image_Widget; Img : Trinket.Images.Image);
   --  Swap the borrowed image and mark dirty (milestone 68: worker
   --  tasks decode images off the event thread and hand them over
   --  via the window app port). The app still owns Load/Free — free
   --  the PREVIOUS image only after the swap, so the widget never
   --  references freed pixels.

end Trinket.Widgets.Image;
