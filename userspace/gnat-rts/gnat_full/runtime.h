/*  Minimal runtime.h for the STANDALONE adaint.c build (53b):
 *  bb-runtimes ships the real one; the gcc tarball does not.
 *  Only what adaint.c/cstreams.c actually consume. */
#ifndef AKERNEL_RUNTIME_H
#define AKERNEL_RUNTIME_H

/*  tsystem.h supplies this in gcc build trees. */
#ifndef ATTRIBUTE_UNUSED
#define ATTRIBUTE_UNUSED __attribute__((unused))
#endif

#endif
