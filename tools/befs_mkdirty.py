#!/usr/bin/env python3
#  befs_mkdirty.py — test fixture for the M82e journal replay.
#
#  Injects a pending (crashed-mid-commit) journal transaction into
#  a BeFS partition image: one run_array block + one content block
#  whose destination is README.TXT's data block, with the ORIGINAL
#  content (so replay is a semantic no-op). The superblock is left
#  DIRT with log_start != log_end, exactly what a crash between
#  the log write and the clean checkpoint leaves behind.
#
#  The guest's Bfs_Engine must replay it at mount (printing
#  "bfs: journal replayed") and re-checkpoint; every fuzz check
#  then sees unchanged fixture contents.
#
#  M93: Sys: is a multi-AG BeFS volume and the fuzz suite splits
#  the root-directory btree at runtime, so the original walk (leaf
#  at the stream's second block) no longer locates README.TXT.
#  The lookup now reuses befs_dump.py's AG-aware, depth-aware
#  btree walker.
#
#  usage: befs_mkdirty.py IMAGE OFFSET_BYTES

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import befs_dump  # noqa: E402  (run(), le64(), Befs, ...)

def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: befs_mkdirty.py IMAGE OFFSET_BYTES")
    with open(sys.argv[1], "rb") as f:
        f.seek(int(sys.argv[2]))
        buf = f.read()  #  whole partition (256 MiB; direct-run streams)

    b = befs_dump.Befs(buf)
    blk = b.block_size
    if b.num_blocks == 0 or b.log_start != b.log_end:
        raise SystemExit("log already dirty or unreadable — replay it first")

    #  Root directory btree -> README.TXT inode -> first data run.
    root_node = b.inode(b.root_dir[0])
    found = None
    for key, val in b.btree_entries(b.read_stream(root_node)):
        if key == b"README.TXT":
            found = val
            break
    if found is None:
        raise SystemExit("README.TXT not found")
    inode = b.inode(found)
    data_blk = bf_run_start(inode)
    content = b.block(data_blk)

    #  Transaction at log position log_start: run_array + content.
    log_start, log_len = b.log_blocks
    pos = b.log_end % log_len
    arr = bytearray(blk)
    struct.pack_into("<ii", arr, 0, 1, 127)      #  count, max_runs
    #  Run record: (ag = block >> ag_shift, start = block mod group).
    gsz = 1 << b.ag_shift
    struct.pack_into("<iHH", arr, 8,
                     data_blk >> b.ag_shift, data_blk % gsz, 1)
    base = (log_start + pos) * blk
    buf = bytearray(buf)
    buf[base:base + blk] = arr
    buf[base + blk:base + 2 * blk] = content

    #  Superblock: DIRT, log_end past the transaction.
    struct.pack_into("<I", buf, 512 + 84, 0x44495254)   #  'DIRT'
    struct.pack_into("<q", buf, 512 + 96, b.log_start)
    struct.pack_into("<q", buf, 512 + 104, b.log_end + 2)

    with open(sys.argv[1], "r+b") as f:
        f.seek(int(sys.argv[2]))
        f.write(buf)
    print("befs_mkdirty: journaled block %d at log %d..%d (DIRT)"
          % (data_blk, b.log_end, b.log_end + 2))


def bf_run_start(node):
    #  First data-stream run of an inode, as a GLOBAL block number
    #  (AG-aware, matching the M93 run encoding).
    return befs_dump.run(node, 72)[0]


if __name__ == "__main__":
    main()
