with Ada.Unchecked_Deallocation;
with Interfaces;
with Akernel_User.Files;
with Trinket.Images.Bmp;
with Trinket.Images.Xpm;

package body Trinket.Images is
   use type U64;
   use type Pixel;
   use type System.Address;
   package Files renames Akernel_User.Files;

   type Byte_Span is array (U64 range <>) of Interfaces.Unsigned_8;
   type Byte_Access is access Byte_Span;
   procedure Free_Bytes is
     new Ada.Unchecked_Deallocation (Byte_Span, Byte_Access);

   Max_File : constant U64 := 1024 * 1024;
   --  An image bigger than 1 MiB compressed is not an icon set
   --  member; keeps the slurp allocation inside the 2 MiB heap.

   procedure Free_Span is
     new Ada.Unchecked_Deallocation (Pixel_Data, Pixel_Access);

   procedure Load (Path : String; Img : out Image; St : out Status) is
      Size  : U64;
      Count : U64;
      Fst   : U64;
   begin
      Img := (others => <>);
      St  := IO_Error;

      Fst := Files.Open (Path, Size);
      if Fst /= Files.Status_Ok or else Size = 0 or else Size > Max_File
      then
         return;
      end if;

      declare
         Buf : Byte_Access := new Byte_Span (1 .. Size);
      begin
         Fst := Files.Read (Path, 0, Buf.all'Address, Size, Count);
         if Fst = Files.Status_Ok and then Count = Size then
            --  Datatype dispatch: magic-sniff in decoder order.
            if Bmp.Claims (Buf.all'Address, Size) then
               Bmp.Decode (Buf.all'Address, Size, Img, St);
            elsif Xpm.Claims (Buf.all'Address, Size) then
               Xpm.Decode (Buf.all'Address, Size, Img, St);
            else
               St := Unsupported;
            end if;
         end if;
         Free_Bytes (Buf);
      end;

      Fst := Files.Close (Path);
   end Load;

   procedure Free (Img : in out Image) is
   begin
      if Img.Data /= null then
         Free_Span (Img.Data);
      end if;
      Img := (others => <>);
   end Free;

   procedure Blit (C : Canvas; Img : Image; DX, DY : U64) is
      Pix : Pixel_Array (0 .. C.W * C.H - 1) with Address => C.Base;
      --  Clipped destination window [X0, X1) x [Y0, Y1), and the
      --  matching source origin.
      X0 : constant U64 := (if DX > C.CX0 then DX else C.CX0);
      Y0 : constant U64 := (if DY > C.CY0 then DY else C.CY0);
      X1 : constant U64 :=
        (if DX + Img.W < C.CX1 then DX + Img.W else C.CX1);
      Y1 : constant U64 :=
        (if DY + Img.H < C.CY1 then DY + Img.H else C.CY1);
      SX0 : constant U64 := X0 - DX;
      SY0 : constant U64 := Y0 - DY;
      Col : Pixel;
   begin
      if not Loaded (Img) or else X0 >= X1 or else Y0 >= Y1 then
         return;
      end if;
      for Y in Y0 .. Y1 - 1 loop
         declare
            SBase : constant U64 := (SY0 + (Y - Y0)) * Img.W;
            DBase : constant U64 := Y * C.W;
         begin
            if Img.Has_Key then
               for X in X0 .. X1 - 1 loop
                  Col := Img.Data (SBase + SX0 + (X - X0));
                  if Col /= Img.Key then
                     Pix (DBase + X) := Col;
                  end if;
               end loop;
            else
               for X in X0 .. X1 - 1 loop
                  Pix (DBase + X) := Img.Data (SBase + SX0 + (X - X0));
               end loop;
            end if;
         end;
      end loop;
   end Blit;

end Trinket.Images;
