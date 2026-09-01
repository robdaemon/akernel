.PHONY: all clean

#  m82a: gprbuild needs --db to see tools/gprkb/ (the AKERNEL-GXX
#  compiler description for the vendored xPack g++); `alr build`
#  cannot forward it, so invoke gprbuild through `alr exec` with
#  the same switches alr uses.
all:
	alr exec -- gprbuild -s -j0 -p --db ../../tools/gprkb -P cxx_test.gpr

clean:
	alr clean
