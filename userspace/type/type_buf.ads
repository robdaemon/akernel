package Type_Buf is
   --  Chunk staging, library-level: a main-procedure local of
   --  this size lands on the 16 KiB user stack and blows past
   --  the mapped pages (milestone-33a burn, the init-stack burn
   --  redux).
   Chunk : String (1 .. 32768);
end Type_Buf;
