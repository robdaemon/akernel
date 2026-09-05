with Trinket.Paint;
with Trinket.Fonts;

package body Trinket.Widgets.Label is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Label_Access is access Label;

   --  Label

   function New_Label
     (S : String; Align : Alignment := Left; Inset : Boolean := False)
      return Any_Widget
   is
      L : constant Label_Access := new Label;
   begin
      Set_Text (L.Txt, L.Len, S);
      L.Align := Align;
      L.Inset := Inset;
      return Any_Widget (L);
   end New_Label;

   procedure Draw (W : Label; C : Canvas) is
      LH : constant U64 := Fonts.Line_Height;
      TY : constant U64 :=
        W.Y + (if W.H > LH then (W.H - LH) / 2 else 0);
      TX : U64;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      if W.Inset then
         Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H, Pane);
         Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                      Raised => False);
      end if;
      TX := (if W.Align = Center
             then W.X + (W.W - Min (W.W, Fonts.Text_Width
                                      (W.Txt (1 .. W.Len)))) / 2
             else W.X + (if W.Inset then 6 else 2));
      Fonts.Draw_Text
        (C, TX, TY + (if W.Inset then 2 else 0),
         W.Txt (1 .. W.Len), Text_Dark);
   end Draw;

   procedure Set_Text (W : in out Label; S : String) is
   begin
      Set_Text (W.Txt, W.Len, S);
      W.Dirty := True;
   end Set_Text;

   procedure Min_Size (W : Label; MW, MH : out U64) is
      LH : constant U64 := Fonts.Line_Height;
   begin
      --  Inset: 6px text pad + 2px bevel each way, and the same
      --  vertical slack Input needs (text draws at TY+2).
      MW := Fonts.Text_Width (W.Txt (1 .. W.Len))
        + (if W.Inset then 8 else 4);
      MH := LH + (if W.Inset then 8 else 0);
   end Min_Size;

end Trinket.Widgets.Label;
