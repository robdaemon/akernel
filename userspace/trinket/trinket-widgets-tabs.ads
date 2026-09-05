--  Tabs (M87e): MUI register-group lineage — a tab strip across
--  the top, one page per tab. Pages are the Group kids (Add_Tab
--  appends); only the SELECTED page is laid out, drawn and
--  dispatched. Tabs have chamfered (rounded) top corners,
--  Tab_Gap between them, and NO bottom edge of their own — the
--  page frame's top line is the shared boundary; the active
--  tab's fill runs 2px lower, covering the frame bevel in its
--  span (merged into the page). M86c battery: hover brightens
--  an inactive tab, a held press shifts its label; per-tab
--  disabled doesn't map onto a strip (apps add/remove pages
--  instead), so it isn't modeled. Switching pages full-redraws
--  the widget and re-lays-out. M87h: a focused strip's
--  Left/Right switch pages (wrap); all other keys fall through
--  to the active page.
package Trinket.Widgets.Tabs is

   type Tab_Callback is access procedure (Index : Natural);

   type Tabs is new Group with record
      Labels    : Text_Array;
      Sel       : Natural := 0;   --  1-based; 0 until first Add_Tab
      Hover_Tab : Natural := 0;   --  0 = pointer not on a tab
      Press_Tab : Natural := 0;   --  tab held down (M86c)
      On_Change : Tab_Callback := null;
   end record;
   function New_Tabs
     (On_Change : Tab_Callback := null) return Any_Widget;
   procedure Add_Tab (W : in out Tabs; Label : String; Page : Any_Widget);
   procedure Set_Selected (W : in out Tabs; I : Natural);
   function Selected (W : Tabs) return Natural;
   overriding procedure Layout (W : in out Tabs);
   overriding procedure Min_Size (W : Tabs; MW, MH : out U64);
   overriding procedure Draw (W : Tabs; C : Canvas);
   overriding function On_Pointer
     (W : access Tabs; K : Pointer_Kind; PX, PY : U64)
      return Boolean;
   overriding function Wants_Focus (W : Tabs) return Boolean;
   overriding function On_Key
     (W : access Tabs; Code : U64) return Boolean;
   --  Damage: a dirty Tabs redraws whole; otherwise only the
   --  ACTIVE page can contribute bands (hidden pages' stale
   --  flags are dropped, not unioned as zero rects).
   overriding procedure Dirty_List
      (W        : Tabs;
       Rects    : in out Rect_Array;
       N        : in out Natural;
       Overflow : in out Boolean);

end Trinket.Widgets.Tabs;
