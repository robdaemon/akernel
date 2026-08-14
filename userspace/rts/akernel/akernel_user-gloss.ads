--  Milestone 53b: newlib libgloss-style syscall layer, in Ada.
--
--  The toolchain ships prebuilt newlib (libc.a/libm.a + headers)
--  but no libgloss, so the ~20 syscalls newlib's stdio/reent
--  machinery references are implemented here, exported with their
--  C names (_open/_read/_write/...), over the existing userspace
--  primitives: file ops go through Akernel_User.Files (fs endpoint,
--  stateless path+offset protocol), stdout/stderr through
--  Akernel_User.Console (so shell redirection composes), process
--  exit through Syscalls.Process_Exit. _sbrk has its OWN VA arena
--  at 0x5200_0000 (memobj chunks, same pattern as s-memory's heap)
--  so newlib's malloc never touches the GNAT heap at 0x4000_0000.
--
--  fd model: 0/1/2 are the console (stdin reads return EOF for
--  now — console input is the terminal input queue, not an fs
--  endpoint); fds 3..18 are path-backed files (the fs protocol is
--  stateless, so the table keeps path + running offset + flags
--  and every op re-qualifies through Files).
--
--  Both the plain (_read) and reentrant (_read_r) spellings are
--  exported; the _r variants ignore the reent pointer. Fork/exec
--  family stubs fail ENOSYS.

package Akernel_User.Gloss is
   pragma Elaborate_Body;
   --  No visible API: every entry point is a C export for newlib.
end Akernel_User.Gloss;
