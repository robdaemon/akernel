with Netserv_Engine;

--  Netserv: thin main; the server lives in Netserv_Engine (a
--  library-level package so the lwIP glue's Ada-side callbacks
--  can be Convention-C exports — local subprograms cannot be
--  exported). See netserv_engine.adb for the full description.

procedure Netserv is
begin
   Netserv_Engine.Run;
end Netserv;
