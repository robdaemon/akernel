with System;

--  Virtqueue structures (virtio 1.2 §2.7, split rings). The driver
--  supplies the three ring areas (descriptor table, available ring,
--  used ring) as DMA memory it allocated and mapped; this package
--  overlays the layout and provides chain building + submission.
--  Single-threaded, one queue per Queue value; Num <= 16.

package Virtio.Queues is
   Max_Num : constant := 16;

   type Queue is limited private;

   --  Desc/Avail/Used are the driver-virtual addresses of the ring
   --  areas (page-sized is plenty at Num <= 16). Areas are zeroed
   --  here and the free-descriptor list is built.
   procedure Initialize
     (Q     : in out Queue;
      Desc  : System.Address;
      Avail : System.Address;
      Used  : System.Address;
      Num   : U16);

   --  Descriptor allocation (simple free list). Alloc returns
   --  No_Desc when exhausted; chains are built with Set_Buffer +
   --  Chain_Next (last descriptor keeps Desc_F_Next clear).
   function Alloc (Q : in out Queue) return U16;
   procedure Free (Q : in out Queue; Head : U16);

   --  Point descriptor Index at the buffer [PA, PA + Length);
   --  Device_Writes marks it Desc_F_Write (device-to-driver data).
   procedure Set_Buffer
     (Q             : in out Queue;
      Index         : U16;
      PA            : U64;
      Length        : U32;
      Device_Writes : Boolean);

   --  Link Index -> Next (sets Desc_F_Next on Index).
   procedure Chain_Next (Q : in out Queue; Index : U16; Next : U16);

   --  Publish the chain headed by Head in the available ring and
   --  memory-barrier (fence rw,rw) so the device sees the
   --  descriptors before the driver notifies the MMIO doorbell.
   procedure Submit (Q : in out Queue; Head : U16);

   --  Poll the used ring for a completed chain since the last Poll
   --  or Pop. Has_Completed reports without consuming; Pop returns
   --  the head descriptor id and the device-written byte count.
   function Has_Completed (Q : Queue) return Boolean;
   procedure Pop
     (Q      : in out Queue;
      Head   : out U16;
      Length : out U32);

private
   type Queue is limited record
      Desc      : System.Address := System.Null_Address;
      Avail     : System.Address := System.Null_Address;
      Used      : System.Address := System.Null_Address;
      Num       : U16 := 0;
      Free_Head : U16 := No_Desc;
      Free_Count : U16 := 0;
      Avail_Idx : U16 := 0;
      Used_Idx  : U16 := 0;
   end record;
end Virtio.Queues;
