with Trinket.Widgets;

--  Trinket window (milestone 56): wraps the Bureau window
--  protocol v3 dance — input queue memobj, thread-bound
--  notification, surface chunk caps, commit — plus the event
--  loop: input events dispatch into the widget tree, dirty
--  widgets union into one damage band, Surface_Update pushes
--  it. A Trinket program is:
--
--     Win : Trinket.Window.Window;
--     ...
--     if Open (Win, 3, 400, 300, "Title", Root) then
--        Run (Win);               --  until the close gadget
--        Close (Win);
--     end if;
--
--  (3 = Bureau service handle under the uniform ABI.)
package Trinket.Window is

   type Window is limited private;

   function Open
     (W         : in out Window;
      Bureau_EP : U64;
      Req_W     : U64;
      Req_H     : U64;
      Title     : String;
      Root      : Widgets.Any_Widget) return Boolean;
   --  False on any setup failure (nothing left mapped/created
   --  that Close wouldn't release anyway — process teardown
   --  reclaims).

   procedure Run (W : in out Window);
   --  Event loop: returns when Bureau delivers the close-gadget
   --  event OR the app calls Request_Quit (e.g. a Quit button).
   --  Draws pending damage before each blocking receive.

   procedure Request_Quit (W : in out Window);

   procedure Close (W : in out Window);

   function Surf_Width (W : Window) return U64;
   function Surf_Height (W : Window) return U64;

private

   type Syscall_Handle_Array is array (0 .. 3) of U64;

   type Window is limited record
      EP           : U64 := 0;
      Id           : U64 := 0;
      Sink_EP      : U64 := 0;
      Ntfn_Cap     : U64 := 0;
      Queue_Cap    : U64 := 0;
      Chunk_Caps   : Syscall_Handle_Array;
      Root         : Widgets.Any_Widget := null;
      Cnv          : Canvas;
      Opened       : Boolean := False;
      Quit_Wanted  : Boolean := False;
      Prev_Buttons : U64 := 0;
   end record;

end Trinket.Window;
