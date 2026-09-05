with Trinket.Images;

package body Trinket.Widgets.Image is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Image_Access is access Image_Widget;

   --  Image widget: centered 1:1 blit, color-key honored.
   function New_Image (Img : Trinket.Images.Image) return Any_Widget is
      I : constant Image_Access := new Image_Widget;
   begin
      I.Img := Img;
      return Any_Widget (I);
   end New_Image;

    overriding procedure Draw (W : Image_Widget; C : Canvas) is
       DX : U64 := W.X;
       DY : U64 := W.Y;
       C2 : Canvas := C;
    begin
       if not Trinket.Images.Loaded (W.Img) then
          return;
       end if;
       if W.W > W.Img.W then
          DX := W.X + (W.W - W.Img.W) / 2;
       end if;
       if W.H > W.Img.H then
          DY := W.Y + (W.H - W.Img.H) / 2;
       end if;
       --  Clip to our own rect: a slice thinner than the image
       --  must not spill over the group frame (M86e overflow).
       Set_Clip (C2, W.X, W.Y, W.X + W.W, W.Y + W.H);
       Trinket.Images.Blit (C2, W.Img, DX, DY);
    end Draw;

   procedure Set_Image
     (W : in out Image_Widget; Img : Trinket.Images.Image) is
   begin
      W.Img := Img;
      W.Dirty := True;
   end Set_Image;

   overriding procedure Min_Size (W : Image_Widget; MW, MH : out U64) is
   begin
      MW := W.Img.W;
      MH := W.Img.H;
   end Min_Size;

end Trinket.Widgets.Image;
