with Trinket.Widgets;
with Trinket.Menus;
with Trinket.App_Port;

--  Trinket window (milestone 56): wraps the Bureau window
--  protocol v3 dance — input queue memobj, thread-bound
--  notification, surface chunk caps, commit — plus the event
--  loop: input events dispatch into the widget tree, dirty
--  widgets collect into per-cluster damage bands (union
--  fallback past Max_Damage), Surface_Update pushes each. A Trinket program is:
--
--     Win : Trinket.Window.Window;
--     ...
--     if Open (Win, 3, 400, 300, "Title", Root) then
--        Run (Win);               --  until the close gadget
--        Close (Win);
--     end if;
--
--  (3 = Bureau service handle under the uniform ABI.)
--
--  Tasking (milestone 68): the thread that calls Open and Run is
--  the event-dispatch thread — the ONLY thread allowed to touch
--  the widget tree and canvas (Swing's EDT rule). Worker tasks
--  report through Post; Run dispatches posted messages to the
--  app handler on the loop thread. Request_Quit is Post-based
--  and safe from any thread. Open and Run must run on the same
--  thread (the input notification is bound to Open's caller).
package Trinket.Window is

   type Window is limited private;

    function Open
      (W         : in out Window;
       Bureau_EP : U64;
       Req_W     : U64;
       Req_H     : U64;
       Title     : String;
       Root      : Widgets.Any_Widget;
       Resizable : Boolean := True) return Boolean;
    --  False on any setup failure (nothing left mapped/created
    --  that Close wouldn't release anyway — process teardown
    --  reclaims). Resizable (v5) opts into the zoom gadget: the
    --  window then answers Bureau's kind-5 resize events by
    --  reallocating its surface and re-laying out the widget
    --  tree. Group-based proportional layouts zoom for free.
    --  Req_W/Req_H are a REQUEST: the surface opens at least at
    --  the root's Min_Size (M86g content negotiation), so apps
    --  express a preference, not a load-bearing pixel budget.

   procedure Run (W : in out Window);
   --  Event loop: returns when Bureau delivers the close-gadget
   --  event OR the app calls Request_Quit (e.g. a Quit button).
   --  Draws pending damage before each blocking receive.

   procedure Request_Quit (W : in out Window);
   --  Posts the reserved quit message; safe from any thread.

   --  Milestone 68: app messages from worker tasks. Post queues a
   --  (Code, A0, A1, A2) message (codes >= 1; 0 is the reserved
   --  quit code) and wakes the loop thread; Run dispatches each
   --  message to the handler installed with Set_App_Handler.
   --  Post is callable from ANY thread of the process (multi-
   --  producer safe, drop-new when the ring is full => False).
   function Post
     (W             : in out Window;
      Code, A0, A1, A2 : U64) return Boolean;
   procedure Set_App_Handler
     (W : in out Window; Cb : App_Port.Msg_Callback);

   --  Milestone 61: Amiga screen-bar menus. Set_Menus declares
   --  the tree (chrome — Bureau renders/operates it; RMB opens
   --  the bar, see akernel_user-window.ads); Set_Menu_Handler
   --  installs the pick callback (item Id). Set_Menus needs the
   --  surface id, so call it AFTER Open; a window with no
   --  Set_Menus shows no bar menus.
   type Menu_Callback is access procedure (Id : U64);
   procedure Set_Menus
     (W : in out Window; Menus : Trinket.Menus.Menu_Array);
   procedure Set_Menu_Handler
     (W : in out Window; Cb : Menu_Callback);

   procedure Close (W : in out Window);

   --  M88: in-window popup/overlay. Open_Popup floats a widget
   --  tree ABOVE the content at a content-absolute position
   --  (sized to its Min_Size, clamped into the surface; a second
   --  Open closes the first). While active the overlay draws
   --  last and gets input first; dismissal rules live here, not
   --  in the widget: a pick (completed release inside), a press
   --  outside, or Escape closes it — the closing press is
   --  swallowed, and keys/Tab never reach the tree behind.
   --  Open_Popup is an event-loop call (EDT rule, like
   --  everything widget-touching).
   procedure Open_Popup
     (W : in out Window; Panel : Widgets.Any_Widget; X, Y : U64);
   procedure Close_Popup (W : in out Window);
   function Popup_Active (W : Window) return Boolean;

   function Surf_Width (W : Window) return U64;
   function Surf_Height (W : Window) return U64;

private

    --  16 chunks x 64 pages = 4 MiB — half the reserved 8 MiB
    --  Surf_VA window; a zoomed pane at 1024x768 (1016x721) needs
    --  12 chunks. Headroom landed WITH the v5 zoom consumer.
    type Syscall_Handle_Array is array (0 .. 15) of U64;

    type Window is limited record
       EP           : U64 := 0;
       Id           : U64 := 0;
       Sink_EP      : U64 := 0;
       Ntfn_Cap     : U64 := 0;
       Queue_Cap    : U64 := 0;
       AppQ_Cap     : U64 := 0;
       Chunk_Caps   : Syscall_Handle_Array;
       N_Chunks     : Natural := 0;
       Surf_Pages   : U64 := 0;
       Root         : Widgets.Any_Widget := null;
       Cnv          : Canvas;
       Opened       : Boolean := False;
       Quit_Wanted  : Boolean := False;
       Prev_Buttons : U64 := 0;
       On_Menu      : Menu_Callback := null;
       On_App       : App_Port.Msg_Callback := null;
       App_Port     : Trinket.App_Port.Port;
       --  M88 overlay: the floating widget + the repaint band
       --  it vacated on Close_Popup.
       Overlay      : Widgets.Any_Widget := null;
       Pend_X0, Pend_Y0, Pend_X1, Pend_Y1 : U64 := 0;
       Has_Pending  : Boolean := False;
    end record;

end Trinket.Window;
