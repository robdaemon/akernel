private with System.Memory;
--  Pulls the custom s-memory.adb (heap over memory objects) into the
--  build closure of every userspace program; the linker then prefers
--  it over the light runtime's bump allocator.

package Akernel_User is
end Akernel_User;
