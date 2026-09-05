--  Desktop (M92): the Workbench-style launcher. One full-screen
--  borderless BACKDROP window under every real window, carrying
--  the mounted fs volumes as 32x32 icons; double-click opens the
--  volume in System/Drawer. Volumes are polled (no mount fan-out
--  exists yet) — the Desktop menu's Refresh re-reads the list.
--  Screen-mode switches (M90) arrive as kind-6 events and
--  Trinket.Window's ack re-fills the new screen. Thin main +
--  library-level app package (callbacks must be library level).
package Desktop_App is
   procedure Main;
end Desktop_App;
