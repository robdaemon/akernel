with Trinket.Paint;
with Trinket.Fonts;
with Akernel_User.Theme;

package body Trinket.Widgets.Button is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Button_Access is access Button;

   --  Button

   function New_Button
     (S        : String;
      On_Click : Click_Callback := null;
      Disabled : Boolean        := False) return Any_Widget
   is
      B : constant Button_Access := new Button;
   begin
      Set_Text (B.Txt, B.Len, S);
      B.On_Click := On_Click;
      B.Disabled := Disabled;
      return Any_Widget (B);
   end New_Button;

   procedure Draw (W : Button; C : Canvas) is
      LH : constant U64 := Fonts.Line_Height;
      TW : constant U64 := Fonts.Text_Width (W.Txt (1 .. W.Len));
      Shift : constant U64 := (if W.Pressed then 1 else 0);
      TX : constant U64 :=
        W.X + (if W.W > TW then (W.W - TW) / 2 else 0) + Shift;
      TY : constant U64 :=
        W.Y + (if W.H > LH then (W.H - LH) / 2 else 0) + Shift;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      --  M86c: hover brightens the face; disabled stays flat.
      Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                       (if W.Hover and then not W.Disabled
                          and then not W.Pressed
                        then Akernel_User.Theme.Face_Hi
                        else Face));
      Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                   Raised => not W.Pressed);
      if W.Disabled then
         --  Ghosted: embossed label, light copy under dark.
         Fonts.Draw_Text (C, TX + 1, TY + 1, W.Txt (1 .. W.Len),
                          Bevel_Hi);
         Fonts.Draw_Text (C, TX, TY, W.Txt (1 .. W.Len),
                          Bevel_Lo);
      else
         Fonts.Draw_Text (C, TX, TY, W.Txt (1 .. W.Len),
                          Text_Dark);
      end if;
      if W.Focused then
         Paint.Focus_Ring (C, W.X + 3, W.Y + 3,
                           W.X + W.W - 3, W.Y + W.H - 3, Text_Dark);
      end if;
   end Draw;

   procedure Min_Size (W : Button; MW, MH : out U64) is
   begin
      --  Centered label: 2px bevel + 2px breathing room per side
      --  (LH + 8 vertically — the +4 floor left the glyph cell
      --  touching the bottom bevel, descenders included).
      MW := Fonts.Text_Width (W.Txt (1 .. W.Len)) + 8;
      MH := Fonts.Line_Height + 8;
   end Min_Size;
   function On_Pointer
     (W : access Button; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
   begin
      if W.Disabled then
         return False;
      end if;
      case K is
         when Press =>
            if Inside (W.all, PX, PY) then
               W.Pressed := True;
               W.Focused := True;   --  M87h: click takes focus
               W.Dirty := True;
               return True;
            end if;
         when Release =>
            if W.Pressed then
               W.Pressed := False;
               W.Dirty := True;
               if Inside (W.all, PX, PY)
                 and then W.On_Click /= null
               then
                  W.On_Click.all;
               end if;
               return True;
            end if;
         when Move =>
            --  Hover tracking: never consume an unpressed move,
            --  so sibling widgets clear/set their own hover.
            declare
               Now_In : constant Boolean := Inside (W.all, PX, PY);
            begin
               if Now_In /= W.Hover then
                  W.Hover := Now_In;
                  W.Dirty := True;
               end if;
            end;
            return W.Pressed;
      end case;
      return False;
   end On_Pointer;

   function Wants_Focus (W : Button) return Boolean is
     (not W.Disabled);  --  M87h: disabled gadgets skip the chain

   function On_Key (W : access Button; Code : U64) return Boolean is
   begin
      --  M87h: Enter/Space activates the focused button.
      if not W.Focused or else W.Disabled then
         return False;
      end if;
      if Code = Key_Return or else Code = 13 or else Code = 32 then
         if W.On_Click /= null then
            W.On_Click.all;
         end if;
         return True;
      end if;
      return False;
   end On_Key;


end Trinket.Widgets.Button;
