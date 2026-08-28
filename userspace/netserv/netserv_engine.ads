--  Netserv_Engine: the netserv server proper, as a library-level
--  package so the lwIP glue's Ada-side callbacks (aknet_frame_tx,
--  aknet_on_udp_rx, aknet_on_icmp_rx) can be Convention-C exports
--  (local subprograms cannot be exported). netserv.adb is a thin
--  main that calls Run. See the body for the full description.

package Netserv_Engine is

   --  Bring up the stack and run the service loop (never returns).
   procedure Run;

end Netserv_Engine;
